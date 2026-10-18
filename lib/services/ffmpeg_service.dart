import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/project.dart';
import '../render/mask_painter.dart';
import '../render/overlay_painter.dart';
import 'export_command.dart';

class MediaInfo {
  const MediaInfo({
    required this.duration,
    required this.hasAudio,
    required this.hasVideo,
    this.width = 0,
    this.height = 0,
  });
  final Duration duration;
  final bool hasAudio;
  final bool hasVideo;
  final int width;
  final int height;
}

class ExportException implements Exception {
  ExportException(this.message, [this.log]);
  final String message;
  final String? log;
  @override
  String toString() => message;
}

/// Tutto ciò che parla con FFmpeg passa da qui.
class FFmpegService {
  int? _runningSessionId;

  /// Legge durata e tracce di un file con ffprobe.
  Future<MediaInfo> probe(String path) async {
    final session = await FFprobeKit.getMediaInformation(path);
    final info = session.getMediaInformation();
    if (info == null) {
      throw ExportException('Impossibile leggere il file: ${p.basename(path)}');
    }
    final seconds = double.tryParse(info.getDuration() ?? '') ?? 0;
    final streams = info.getStreams();
    final types = streams.map((s) => s.getType()).toSet();
    var w = 0, h = 0;
    for (final s in streams) {
      if (s.getType() == 'video') {
        w = s.getWidth() ?? 0;
        h = s.getHeight() ?? 0;
        // Video girati in verticale: lo stream è orizzontale + rotazione.
        final rot = int.tryParse('${s.getTags()?['rotate'] ?? ''}') ?? 0;
        if (rot % 180 != 0) {
          final t = w;
          w = h;
          h = t;
        }
        break;
      }
    }
    return MediaInfo(
      duration: Duration(microseconds: (seconds * 1e6).round()),
      hasAudio: types.contains('audio'),
      hasVideo: types.contains('video'),
      width: w,
      height: h,
    );
  }

  Future<bool> _run(List<String> args) async {
    final session = await FFmpegKit.executeWithArguments(args);
    return ReturnCode.isSuccess(await session.getReturnCode());
  }

  /// Miniature di una clip: un fotogramma ogni [every] del file sorgente.
  /// Restituisce i file in ordine (la miniatura k è all'istante k*every).
  Future<List<String>> thumbnails(String path,
      {Duration every = const Duration(seconds: 1)}) async {
    final cache = await getTemporaryDirectory();
    final dir = Directory(p.join(cache.path, 'thumbs', path.hashCode.toRadixString(16)));
    if (await dir.exists()) {
      final files = (await dir.list().toList())
          .whereType<File>()
          .map((f) => f.path)
          .where((f) => f.endsWith('.jpg'))
          .toList()
        ..sort();
      if (files.isNotEmpty) return files;
    }
    await dir.create(recursive: true);
    final rate = (1e6 / every.inMicroseconds).toStringAsFixed(4);
    await _run([
      '-y', '-i', path, //
      '-vf', 'fps=$rate,scale=-2:96',
      '-q:v', '7',
      p.join(dir.path, 't_%04d.jpg'),
    ]);
    final files = (await dir.list().toList())
        .whereType<File>()
        .map((f) => f.path)
        .where((f) => f.endsWith('.jpg'))
        .toList()
      ..sort();
    return files;
  }

  /// Estrae l'audio della clip così come suona nel video finale
  /// (taglio + velocità), in WAV mono 16 kHz per il riconoscimento vocale.
  Future<String?> speechWav(VideoClip c, String outPath) async {
    if (!c.hasAudio) return null;
    final ok = await _run([
      '-y',
      '-ss', _s(c.trimStart),
      '-to', _s(c.trimEnd),
      '-i', c.path,
      '-vn',
      '-af', 'atempo=${c.speed.clamp(0.5, 2.0).toStringAsFixed(3)}',
      '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le',
      outPath,
    ]);
    return ok ? outPath : null;
  }

  /// Crea una copia al contrario del tratto tagliato di una clip.
  Future<String?> reverse(VideoClip c, String outPath) async {
    final ok = await _run([
      '-y',
      '-ss', _s(c.trimStart),
      '-to', _s(c.trimEnd),
      '-i', c.path,
      '-vf', 'reverse',
      if (c.hasAudio) ...['-af', 'areverse'] else '-an',
      '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18',
      if (c.hasAudio) ...['-c:a', 'aac', '-b:a', '192k'],
      outPath,
    ]);
    return ok ? outPath : null;
  }

  /// Fotogramma della clip all'istante locale [local], salvato come JPG.
  Future<String?> frameAt(VideoClip c, Duration local, String outPath) async {
    final ok = await _run([
      '-y', '-ss', _s(c.sourceAt(local)), '-i', c.path,
      '-frames:v', '1', '-q:v', '2', outPath,
    ]);
    return ok && File(outPath).existsSync() ? outPath : null;
  }

  /// Estrae fotogrammi JPG da [path] (da [start] per [duration]) a [fps]
  /// fotogrammi al secondo, larghi [width] pixel, nella cartella [dir].
  Future<List<String>> extractFrames(String path, Duration start, Duration duration,
      {required double fps, required int width, required String dir, String extraVf = ''}) async {
    await Directory(dir).create(recursive: true);
    await _run([
      '-y', '-ss', _s(start), '-t', _s(duration), '-i', path,
      '-vf', '${extraVf.isEmpty ? '' : '$extraVf,'}fps=${fps.toStringAsFixed(4)},scale=$width:-2',
      '-q:v', '4', p.join(dir, 'f_%05d.jpg'),
    ]);
    final files = (await Directory(dir).list().toList())
        .whereType<File>()
        .map((f) => f.path)
        .where((f) => f.endsWith('.jpg'))
        .toList()
      ..sort();
    return files;
  }

  /// Codifica una sequenza di maschere grezze (gray8) in un video.
  Future<bool> encodeMask(String rawPath, int w, int h, double fps, String outPath) =>
      _run([
        '-y', '-f', 'rawvideo', '-pix_fmt', 'gray', '-s', '${w}x$h',
        '-r', fps.toStringAsFixed(4), '-i', rawPath,
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '16', '-pix_fmt', 'yuv420p',
        outPath,
      ]);

  /// Fotogrammi in scala di grigi grezzi (per il tracciamento).
  Future<String?> grayFrames(String path, Duration start, Duration duration,
      {required double fps, required int width, required int height, required String outPath,
      String extraVf = ''}) async {
    final ok = await _run([
      '-y', '-ss', _s(start), '-t', _s(duration), '-i', path,
      '-vf', '${extraVf.isEmpty ? '' : '$extraVf,'}fps=${fps.toStringAsFixed(4)},scale=$width:$height,format=gray',
      '-f', 'rawvideo', '-pix_fmt', 'gray', outPath,
    ]);
    return ok ? outPath : null;
  }

  /// Esporta il progetto in MP4. [onProgress] riceve un valore 0–1.
  Future<String> export(
    Project project, {
    void Function(double progress)? onProgress,
    bool highQuality = false,
  }) async {
    final tmp = await getTemporaryDirectory();
    final work = await Directory(
      p.join(tmp.path, 'export_${DateTime.now().millisecondsSinceEpoch}'),
    ).create(recursive: true);

    // Testi, sticker e sottotitoli → PNG a piena risoluzione.
    final rendered = <RenderedOverlay>[];
    for (var i = 0; i < project.overlays.length; i++) {
      final o = project.overlays[i];
      if (o.text.trim().isEmpty) continue;
      final path = p.join(work.path, 'ov_$i.png');
      final (w, h) = await OverlayLayout(o, scale: project.resolution / 1080, frameWidth: project.aspect.width)
          .writePng(path);
      rendered.add(RenderedOverlay(o, path, w, h));
    }

    // Maschere delle sovrapposizioni → PNG alla dimensione del livello.
    final masks = <int, String>{};
    for (var i = 0; i < project.pips.length; i++) {
      final l = project.pips[i];
      if (l.mask == MaskShape.none) continue;
      final exportW = ((project.aspect.width * project.resolution / 1080) / 2).round() * 2;
      final (w, h) = l.pixelSize(exportW, l.maxScale);
      final path = p.join(work.path, 'mask_$i.png');
      await writeMaskPng(l.mask, w, h, path);
      masks[i] = path;
    }

    final docs = await getApplicationDocumentsDirectory();
    final out = p.join(
      docs.path,
      'ClipForge_${DateTime.now().millisecondsSinceEpoch}.mp4',
    );

    final args = ExportCommand(
      project: project,
      outputPath: out,
      overlays: rendered,
      pipMasks: masks,
      preset: highQuality ? 'medium' : 'veryfast',
    ).build();

    final totalMs = project.totalDuration.inMilliseconds.clamp(1, 1 << 31);
    final done = Completer<String>();

    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        _runningSessionId = null;
        final rc = await session.getReturnCode();
        if (ReturnCode.isSuccess(rc)) {
          onProgress?.call(1);
          done.complete(out);
        } else if (ReturnCode.isCancel(rc)) {
          done.completeError(ExportException('Esportazione annullata.'));
        } else {
          final log = await session.getAllLogsAsString();
          done.completeError(
            ExportException('FFmpeg non è riuscito a esportare il video.', log),
          );
        }
        unawaited(work.delete(recursive: true).catchError((_) => work));
      },
      null,
      (stats) {
        final t = stats.getTime();
        if (t > 0) onProgress?.call((t / totalMs).clamp(0.0, 0.99));
      },
    );
    _runningSessionId = session.getSessionId();
    return done.future;
  }

  Future<void> cancel() async {
    final id = _runningSessionId;
    if (id != null) await FFmpegKit.cancel(id);
  }

  static String _s(Duration d) => (d.inMicroseconds / 1e6).toStringAsFixed(3);
}
