import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/project.dart';
import 'export_command.dart';

class MediaInfo {
  const MediaInfo({
    required this.duration,
    required this.hasAudio,
    required this.hasVideo,
  });
  final Duration duration;
  final bool hasAudio;
  final bool hasVideo;
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
    final types = info.getStreams().map((s) => s.getType()).toSet();
    return MediaInfo(
      duration: Duration(microseconds: (seconds * 1e6).round()),
      hasAudio: types.contains('audio'),
      hasVideo: types.contains('video'),
    );
  }

  /// Esporta il progetto in MP4. [onProgress] riceve un valore 0–1.
  Future<String> export(
    Project project, {
    void Function(double progress)? onProgress,
  }) async {
    final tmp = await getTemporaryDirectory();
    final work = await Directory(
      p.join(tmp.path, 'export_${DateTime.now().millisecondsSinceEpoch}'),
    ).create(recursive: true);

    final fontPath = await _materializeFont(work.path);
    final textFiles = <String>[];
    for (var i = 0; i < project.texts.length; i++) {
      final f = File(p.join(work.path, 'text_$i.txt'));
      await f.writeAsString(project.texts[i].text);
      textFiles.add(f.path);
    }

    final docs = await getApplicationDocumentsDirectory();
    final out = p.join(
      docs.path,
      'ClipForge_${DateTime.now().millisecondsSinceEpoch}.mp4',
    );

    final args = ExportCommand(
      project: project,
      outputPath: out,
      fontPath: fontPath,
      textFilePaths: textFiles,
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
        // Pulizia dei file temporanei.
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

  /// drawtext vuole un vero file su disco: copia il font dagli asset.
  Future<String> _materializeFont(String dir) async {
    final data = await rootBundle.load('assets/fonts/Poppins-Bold.ttf');
    final f = File(p.join(dir, 'Poppins-Bold.ttf'));
    await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return f.path;
  }
}
