import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../models/project.dart';
import 'ffmpeg_service.dart';

/// Modelli Whisper scaricabili. Girano interamente sul telefono, offline.
enum WhisperSize {
  tiny('Veloce', 'tiny', '~100 MB'),
  base('Preciso', 'base', '~160 MB');

  const WhisperSize(this.label, this.id, this.download);
  final String label;
  final String id;
  final String download;
}

class SpeechSegment {
  SpeechSegment(this.start, this.end, this.text);
  final double start;
  final double end;
  final String text;
}

/// Sottotitoli automatici: estrae l'audio di ogni clip, trova le parti
/// parlate (Silero VAD) e le trascrive con Whisper via sherpa-onnx.
class SubtitleService {
  SubtitleService(this._ffmpeg);
  final FFmpegService _ffmpeg;

  static const _hf = 'https://huggingface.co/csukuangfj';
  static const _vadUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx';

  static Map<String, String> modelFiles(WhisperSize m) => {
        'encoder.onnx': '$_hf/sherpa-onnx-whisper-${m.id}/resolve/main/${m.id}-encoder.int8.onnx',
        'decoder.onnx': '$_hf/sherpa-onnx-whisper-${m.id}/resolve/main/${m.id}-decoder.int8.onnx',
        'tokens.txt': '$_hf/sherpa-onnx-whisper-${m.id}/resolve/main/${m.id}-tokens.txt',
        'silero_vad.onnx': _vadUrl,
      };

  Future<Directory> _modelDir(WhisperSize m) async {
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'whisper-${m.id}'));
  }

  Future<bool> isDownloaded(WhisperSize m) async {
    final dir = await _modelDir(m);
    for (final name in modelFiles(m).keys) {
      if (!await File(p.join(dir.path, name)).exists()) return false;
    }
    return true;
  }

  /// Scarica il modello (una volta sola). [onProgress] 0–1.
  Future<void> download(WhisperSize m, void Function(double) onProgress) async {
    final dir = await _modelDir(m);
    await dir.create(recursive: true);
    final files = modelFiles(m);
    final client = HttpClient()..userAgent = 'ClipForge';
    try {
      var index = 0;
      for (final entry in files.entries) {
        final target = File(p.join(dir.path, entry.key));
        if (await target.exists()) {
          index++;
          continue;
        }
        final tmp = File('${target.path}.part');
        final req = await client.getUrl(Uri.parse(entry.value));
        final res = await req.close();
        if (res.statusCode != 200) {
          throw HttpException('Download fallito (${res.statusCode}): ${entry.key}');
        }
        final total = res.contentLength;
        var received = 0;
        final sink = tmp.openWrite();
        await for (final chunk in res) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            onProgress((index + received / total) / files.length);
          }
        }
        await sink.close();
        await tmp.rename(target.path);
        index++;
        onProgress(index / files.length);
      }
    } finally {
      client.close();
    }
  }

  /// Genera i sottotitoli per tutto il progetto.
  /// [onProgress] riceve (fase, 0–1).
  Future<List<VideoOverlay>> generate(
    Project project, {
    required WhisperSize model,
    String language = 'it',
    void Function(String phase, double progress)? onProgress,
  }) async {
    final dir = await _modelDir(model);
    final tmp = await getTemporaryDirectory();
    final result = <VideoOverlay>[];
    final clips = project.clips;

    for (var i = 0; i < clips.length; i++) {
      onProgress?.call('Clip ${i + 1} di ${clips.length}', i / clips.length);
      final wav = await _ffmpeg.speechWav(
          clips[i], p.join(tmp.path, 'speech_$i.wav'));
      if (wav == null) continue;

      final segments = await _transcribeInIsolate(wav, dir.path, language);

      final offset = project.startOf(i).inMicroseconds / 1e6;
      final clipEnd = offset + clips[i].outputDuration.inMicroseconds / 1e6;
      for (final s in segments) {
        for (final chunk in _split(s)) {
          final start = offset + chunk.start;
          final end = (offset + chunk.end).clamp(start + 0.3, clipEnd);
          if (start >= clipEnd) continue;
          result.add(VideoOverlay(
            kind: OverlayKind.subtitle,
            text: chunk.text,
            start: Duration(microseconds: (start * 1e6).round()),
            end: Duration(microseconds: (end * 1e6).round()),
            fontSize: 62,
            box: true,
            outline: false,
            cx: 0.5,
            cy: 0.8,
            animIn: AnimIn.none,
            animOut: AnimOut.none,
          ));
        }
      }
      try {
        await File(wav).delete();
      } catch (_) {}
    }
    onProgress?.call('Fatto', 1);
    return result;
  }

  /// Spezza un segmento lungo in righe da max 6 parole, con tempi
  /// proporzionali alla lunghezza del testo.
  static List<SpeechSegment> _split(SpeechSegment s) {
    final words = s.text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const [];
    const maxWords = 6;
    if (words.length <= maxWords) return [s];
    final groups = <List<String>>[];
    for (var i = 0; i < words.length; i += maxWords) {
      groups.add(words.sublist(i, (i + maxWords).clamp(0, words.length)));
    }
    final totalChars = words.join(' ').length;
    final out = <SpeechSegment>[];
    var t = s.start;
    for (final g in groups) {
      final text = g.join(' ');
      final d = (s.end - s.start) * (text.length + 1) / (totalChars + groups.length);
      out.add(SpeechSegment(t, t + d, text));
      t += d;
    }
    return out;
  }
}

/// Funzione top-level: la closure passata all'isolate cattura solo stringhe.
Future<List<SpeechSegment>> _transcribeInIsolate(
        String wav, String modelDir, String language) =>
    Isolate.run(() =>
        _transcribe(wav: wav, modelDir: modelDir, language: language));

/// Gira in un isolate separato per non bloccare l'interfaccia.
List<SpeechSegment> _transcribe({
  required String wav,
  required String modelDir,
  required String language,
}) {
  sherpa.initBindings();
  final vadConfig = sherpa.VadModelConfig(
    sileroVad: sherpa.SileroVadModelConfig(
      model: p.join(modelDir, 'silero_vad.onnx'),
      minSilenceDuration: 0.3,
      minSpeechDuration: 0.25,
      maxSpeechDuration: 8.0,
    ),
    numThreads: 1,
  );
  final vad = sherpa.VoiceActivityDetector(config: vadConfig, bufferSizeInSeconds: 60);
  final recognizer = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
    model: sherpa.OfflineModelConfig(
      whisper: sherpa.OfflineWhisperModelConfig(
        encoder: p.join(modelDir, 'encoder.onnx'),
        decoder: p.join(modelDir, 'decoder.onnx'),
        language: language,
        task: 'transcribe',
      ),
      tokens: p.join(modelDir, 'tokens.txt'),
      modelType: 'whisper',
      numThreads: 2,
    ),
  ));

  final wave = sherpa.readWave(wav);
  final out = <SpeechSegment>[];

  void drain() {
    while (!vad.isEmpty()) {
      final seg = vad.front();
      final start = seg.start / wave.sampleRate;
      final end = start + seg.samples.length / wave.sampleRate;
      final stream = recognizer.createStream();
      stream.acceptWaveform(samples: seg.samples, sampleRate: wave.sampleRate);
      recognizer.decode(stream);
      final text = recognizer.getResult(stream).text.trim();
      stream.free();
      if (text.isNotEmpty) out.add(SpeechSegment(start, end, text));
      vad.pop();
    }
  }

  final window = vadConfig.sileroVad.windowSize;
  final n = wave.samples.length ~/ window;
  for (var i = 0; i < n; i++) {
    vad.acceptWaveform(Float32List.sublistView(wave.samples, i * window, (i + 1) * window));
    drain();
  }
  vad.flush();
  drain();
  vad.free();
  recognizer.free();
  return out;
}
