import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ffmpeg_service.dart';

/// Funzioni "intelligenti" che girano sul telefono:
/// - rimozione dello sfondo (ML Kit Selfie Segmentation, fotogramma per fotogramma)
/// - tracciamento del movimento (confronto di blocchi su fotogrammi ridotti)
class AiService {
  AiService(this._ffmpeg);
  final FFmpegService _ffmpeg;

  static const maskFps = 15.0;
  static const _maskWidth = 256;

  /// Crea un video maschera (bianco = persona) per tutto il file [path].
  /// Restituisce il percorso del video maschera, o null se annullato/fallito.
  Future<String?> removeBackground(
    String path,
    Duration duration, {
    void Function(double progress)? onProgress,
    bool Function()? cancelled,
  }) async {
    final tmp = await getTemporaryDirectory();
    final work = Directory(p.join(tmp.path, 'seg_${DateTime.now().millisecondsSinceEpoch}'));
    final frames = await _ffmpeg.extractFrames(
      path,
      Duration.zero,
      duration,
      fps: maskFps,
      width: _maskWidth,
      dir: work.path,
    );
    if (frames.isEmpty) return null;

    final segmenter = SelfieSegmenter(mode: SegmenterMode.stream);
    final raw = File(p.join(work.path, 'mask.gray')).openWrite();
    int? w, h;
    try {
      for (var i = 0; i < frames.length; i++) {
        if (cancelled?.call() ?? false) return null;
        final mask = await segmenter.processImage(InputImage.fromFilePath(frames[i]));
        if (mask == null) continue;
        w ??= mask.width;
        h ??= mask.height;
        final bytes = Uint8List(w * h);
        if (mask.width == w && mask.height == h) {
          final c = mask.confidences;
          for (var k = 0; k < bytes.length && k < c.length; k++) {
            // Curva più netta per bordi puliti.
            final v = ((c[k] - 0.35) / 0.3).clamp(0.0, 1.0);
            bytes[k] = (v * 255).round();
          }
        }
        raw.add(bytes);
        onProgress?.call((i + 1) / frames.length * 0.95);
      }
    } finally {
      await raw.close();
      await segmenter.close();
    }
    if (w == null || h == null) return null;

    final docs = await getApplicationDocumentsDirectory();
    final out = p.join(docs.path, 'media', 'mask_${DateTime.now().millisecondsSinceEpoch}.mp4');
    await Directory(p.dirname(out)).create(recursive: true);
    // x264 vuole dimensioni pari.
    final ok = await _ffmpeg.encodeMask(p.join(work.path, 'mask.gray'), w, h, maskFps, out);
    try {
      await work.delete(recursive: true);
    } catch (_) {}
    onProgress?.call(1);
    return ok ? out : null;
  }

  /// Segue il punto ([x], [y], normalizzati 0–1 nel fotogramma della clip)
  /// per [duration] a partire da [start] del file sorgente.
  /// Restituisce terne (t, x, y) con t in secondi dall'inizio.
  Future<List<double>?> track(
    String path, {
    required Duration start,
    required Duration duration,
    required double x,
    required double y,
    required int srcWidth,
    required int srcHeight,
    double speed = 1,
    String extraVf = '',
  }) async {
    const sampleFps = 10.0;
    const tw = 192;
    final th = math.max(16, (tw * srcHeight / math.max(1, srcWidth)).round() ~/ 2 * 2);
    final tmp = await getTemporaryDirectory();
    final out = p.join(tmp.path, 'track_${DateTime.now().millisecondsSinceEpoch}.gray');
    final ok = await _ffmpeg.grayFrames(
      path,
      start,
      Duration(microseconds: (duration.inMicroseconds * speed).round()),
      fps: sampleFps / speed,
      width: tw,
      height: th,
      outPath: out,
      extraVf: extraVf,
    );
    if (ok == null) return null;
    final data = await File(out).readAsBytes();
    try {
      await File(out).delete();
    } catch (_) {}
    return Isolate.run(() => _trackBlocks(data, tw, th, x, y, sampleFps));
  }
}

/// Tracciamento a blocchi (somma delle differenze assolute) con modello
/// aggiornato lentamente: semplice ma robusto per oggetti che si spostano.
List<double> _trackBlocks(Uint8List data, int w, int h, double x, double y, double fps) {
  final frameSize = w * h;
  final n = data.length ~/ frameSize;
  const r = 10; // mezza dimensione del blocco
  const search = 14; // raggio di ricerca per fotogramma
  var px = (x * w).clamp(r.toDouble(), (w - r - 1).toDouble());
  var py = (y * h).clamp(r.toDouble(), (h - r - 1).toDouble());
  const side = r * 2 + 1;
  final tpl = Float64List(side * side);

  void grab(int f, int cx, int cy, double blend) {
    final base = f * frameSize;
    var k = 0;
    for (var dy = -r; dy <= r; dy++) {
      for (var dx = -r; dx <= r; dx++) {
        final v = data[base + (cy + dy) * w + (cx + dx)].toDouble();
        tpl[k] = blend >= 1 ? v : tpl[k] * (1 - blend) + v * blend;
        k++;
      }
    }
  }

  final out = <double>[0, px / w, py / h];
  grab(0, px.round(), py.round(), 1);
  for (var f = 1; f < n; f++) {
    final base = f * frameSize;
    final cx0 = px.round(), cy0 = py.round();
    var best = double.infinity;
    var bx = cx0, by = cy0;
    for (var sy = math.max(r, cy0 - search); sy <= math.min(h - r - 1, cy0 + search); sy++) {
      for (var sx = math.max(r, cx0 - search); sx <= math.min(w - r - 1, cx0 + search); sx++) {
        var sad = 0.0;
        var k = 0;
        for (var dy = -r; dy <= r && sad < best; dy++) {
          final row = base + (sy + dy) * w + sx;
          for (var dx = -r; dx <= r; dx++) {
            sad += (data[row + dx] - tpl[k]).abs();
            k++;
          }
        }
        // Leggera preferenza per restare vicini (meno salti).
        sad += ((sx - cx0).abs() + (sy - cy0).abs()) * 2;
        if (sad < best) {
          best = sad;
          bx = sx;
          by = sy;
        }
      }
    }
    px = bx.toDouble();
    py = by.toDouble();
    grab(f, bx, by, 0.25);
    out.addAll([f / fps, px / w, py / h]);
  }
  return out;
}
