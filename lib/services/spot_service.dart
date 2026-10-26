import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_mlkit_subject_segmentation/google_mlkit_subject_segmentation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/project.dart';
import 'ai_spot_service.dart' show ShotRole;
import 'photo_analysis.dart';

export 'photo_analysis.dart' show analyzePhoto;

/// Richiesta per lo spot gratuito (solo foto, tutto sul telefono).
class SpotRequest {
  SpotRequest({
    required this.photos,
    required this.brand,
    this.endLine = '',
    this.aspect = AspectRatioPreset.portrait,
  });
  final List<(String, ShotRole)> photos;
  final String brand;
  final String endLine;
  final AspectRatioPreset aspect;
}

class _Still {
  _Still(this.path, this.w, this.h, this.role, {this.isCutout = false});
  final String path;
  final int w, h;
  final ShotRole role;
  final bool isCutout;
}

/// Spot in stile pubblicità di lusso costruito solo dalle foto:
/// - macro in "low-key" (lo sfondo va al nero, brillano metallo e oro),
/// - orologio intero ritagliato (ML Kit Subject Segmentation) su nero,
/// - movimenti di camera lenti e costanti, tagli secchi, riflessi che
///   scorrono sul metallo, emersione dal buio,
/// - colonna sonora generata (ticchettio, salita, colpi bassi).
class SpotService {
  Future<Project> build(SpotRequest r, {void Function(String phase, double progress)? onProgress}) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'media', 'spot_${DateTime.now().millisecondsSinceEpoch}'));
    await dir.create(recursive: true);
    final aspect = r.aspect.width / r.aspect.height;

    // 1) Prepara le foto.
    final stills = <_Still>[];
    var heroIndex = r.photos.indexWhere((e) => e.$2 == ShotRole.hero);
    if (heroIndex < 0) heroIndex = 0;
    for (var i = 0; i < r.photos.length; i++) {
      final (path, role) = r.photos[i];
      onProgress?.call('Preparo la foto ${i + 1} di ${r.photos.length}', i / (r.photos.length + 2));
      if (i == heroIndex) {
        final cut = await _cutout(path, p.join(dir.path, 'hero.png'), aspect);
        if (cut != null) {
          stills.add(cut);
          continue;
        }
      }
      stills.add(await _lowKey(path, p.join(dir.path, 'foto_$i.png'), i == heroIndex ? ShotRole.hero : role));
    }
    final hero = stills.firstWhere((s) => s.role == ShotRole.hero, orElse: () => stills.first);
    final macros = stills.where((s) => !identical(s, hero)).toList()
      ..sort((a, b) => _order(a.role).compareTo(_order(b.role)));

    onProgress?.call('Monto lo spot', 0.85);
    final black = await _solid(p.join(dir.path, 'nero.png'));
    final project = Project(aspect: r.aspect)
      ..background = CanvasBackground.black
      ..fps = 30;

    void add(String path, int w, int h, double secs, KenBurns? kb,
        {ClipEffect effect = ClipEffect.spotlight, TransitionType tr = TransitionType.none, double trSecs = 0.45}) {
      project.clips.add(VideoClip.image(path, duration: Duration(milliseconds: (secs * 1000).round()))
        ..width = w
        ..height = h
        ..motion = kb
        ..effect = effect
        ..transition = tr
        ..transitionDuration = Duration(milliseconds: (trSecs * 1000).round()));
    }

    // Frammenti macro: se le foto sono poche, si usano più zone della stessa foto.
    final fragments = <(_Still, Offset, Offset, double)>[]; // foto, centro, spostamento, ingrandimento
    final sources = macros.isEmpty ? [hero] : macros;
    const spots = [Offset(0.5, 0.5), Offset(0.38, 0.42), Offset(0.62, 0.58), Offset(0.45, 0.62)];
    const moves = [Offset(-0.06, 0), Offset(0.06, -0.03), Offset(0, -0.06), Offset(0.05, 0.04)];
    for (var k = 0; fragments.length < 5; k++) {
      final s = sources[k % sources.length];
      final round = k ~/ sources.length;
      final base = s.role == ShotRole.crown ? const Offset(0.5, 0.6) : spots[round % spots.length];
      fragments.add((s, base, moves[k % moves.length], round == 0 ? 1.0 : 0.72));
      if (k > 12) break;
    }

    // Apertura: dal buio sul primo dettaglio.
    add(black, 16, 16, 0.8, null, effect: ClipEffect.none, tr: TransitionType.fadeBlack, trSecs: 0.35);
    final (s0, c0, m0, z0) = fragments.first;
    add(s0.path, s0.w, s0.h, 2.0, _move(s0, aspect, c0, m0, z0, 0.93), effect: ClipEffect.glint);
    // Frammenti a tempo (tagli secchi).
    for (final (s, c, m, z) in fragments.skip(1).take(4)) {
      add(s.path, s.w, s.h, 0.75, _move(s, aspect, c, m, z, 0.95),
          effect: identical(s, fragments[2].$1) ? ClipEffect.glint : ClipEffect.spotlight);
    }
    // Respiro al nero, poi l'orologio intero emerge dal buio.
    add(black, 16, 16, 1.0, null, effect: ClipEffect.none, tr: TransitionType.fadeBlack, trSecs: 0.45);
    add(hero.path, hero.w, hero.h, 4.6, _heroMove(hero, aspect, push: 0.9), effect: ClipEffect.glint);
    add(hero.path, hero.w, hero.h, 1.9, _heroClose(hero, aspect), effect: ClipEffect.glint,
        tr: TransitionType.fadeBlack, trSecs: 0.5);
    // Chiusura sul marchio.
    add(black, 16, 16, 3.0, null, effect: ClipEffect.none);

    final total = project.totalDuration;
    final endStart = project.startOf(project.clips.length - 1);
    final brand = r.brand.trim().toUpperCase();
    if (brand.isNotEmpty) {
      project.overlays.add(VideoOverlay(
        kind: OverlayKind.text,
        text: brand.split('').join(' '),
        start: endStart + const Duration(milliseconds: 250),
        end: total,
        color: const Color(0xFFE9EBEE),
        fontSize: 70,
        outline: false,
        cy: 0.47,
        animIn: AnimIn.fade,
        animOut: AnimOut.none,
      ));
    }
    if (r.endLine.trim().isNotEmpty) {
      project.overlays.add(VideoOverlay(
        kind: OverlayKind.text,
        text: r.endLine.trim().toUpperCase(),
        start: endStart + const Duration(milliseconds: 900),
        end: total,
        color: const Color(0xFFD9B97A),
        fontSize: 30,
        outline: false,
        cy: 0.535,
        animIn: AnimIn.fade,
        animOut: AnimOut.none,
      ));
    }

    // 3) Colonna sonora sui tagli.
    onProgress?.call('Creo il sonoro', 0.95);
    final cuts = [for (var i = 0; i < project.clips.length; i++) project.startOf(i).inMicroseconds / 1e6];
    final wav = p.join(dir.path, 'sonoro.wav');
    final heroCut = cuts[cuts.length - 3];
    final blackCut = cuts[cuts.length - 4];
    final endCut = cuts.last;
    final totalS = total.inMicroseconds / 1e6;
    final macroCuts = cuts.sublist(2, cuts.length - 4);
    await Isolate.run(() => writeSpotSoundtrack(wav, totalS, macroCuts, blackCut, heroCut, endCut));
    project.audios.add(AudioItem(path: wav, start: Duration.zero, duration: total, isVoice: false));

    onProgress?.call('Fatto', 1);
    return project;
  }

  static int _order(ShotRole r) => switch (r) {
        ShotRole.dial => 0,
        ShotRole.crown => 1,
        ShotRole.logo => 2,
        ShotRole.caseback => 3,
        ShotRole.strap => 4,
        ShotRole.box => 5,
        ShotRole.hero => 6,
      };

  // ───────────────────────── Inquadrature ─────────────────────────

  /// Movimento lineare dentro la finestra più grande con le proporzioni del
  /// video, centrata su [c] (frazioni della foto). [zoom] ≤ 1 restringe la
  /// finestra; [end] è il rapporto tra fine e inizio (lento avvicinamento).
  KenBurns _move(_Still s, double a, Offset c, Offset shift, double zoom, double end) {
    final win = _window(s, a, c);
    final s0 = zoom.clamp(0.4, 1.0);
    final s1 = (s0 * end).clamp(0.35, 1.0);
    // Mai ingrandire oltre ~1,25 volte i pixel reali.
    final minSize = (1080 / 1.25) / (win.width);
    final a0 = math.max(s0, minSize).clamp(0.0, 1.0), a1 = math.max(s1, minSize).clamp(0.0, 1.0);
    ShotRect rect(double size, Offset off) {
      final x = (0.5 + off.dx - size / 2).clamp(0.0, 1 - size);
      final y = (0.5 + off.dy - size / 2).clamp(0.0, 1 - size);
      return ShotRect(x, y, size);
    }

    return KenBurns(
      px: win.left / s.w,
      py: win.top / s.h,
      pw: win.width / s.w,
      ph: win.height / s.h,
      from: rect(a0, -shift / 2),
      to: rect(a1, shift / 2),
      linear: true,
    );
  }

  Rect _window(_Still s, double a, Offset c) {
    var w = s.w.toDouble(), h = w / a;
    if (h > s.h) {
      h = s.h.toDouble();
      w = h * a;
    }
    final x = (c.dx * s.w - w / 2).clamp(0.0, s.w - w);
    final y = (c.dy * s.h - h / 2).clamp(0.0, s.h - h);
    return Rect.fromLTWH(x, y, w, h);
  }

  /// Orologio intero: lento avvicinamento con leggerissima salita.
  KenBurns _heroMove(_Still s, double a, {required double push}) {
    final win = _window(s, a, const Offset(0.5, 0.5));
    return KenBurns(
      px: win.left / s.w,
      py: win.top / s.h,
      pw: win.width / s.w,
      ph: win.height / s.h,
      from: const ShotRect(0, 0.02, 1),
      to: ShotRect((1 - push) / 2, (1 - push) / 2 - 0.01, push),
      linear: true,
    );
  }

  /// Primo piano sulla cassa.
  KenBurns _heroClose(_Still s, double a) {
    final win = _window(s, a, const Offset(0.5, 0.5));
    final minSize = (1080 / 1.25) / win.width;
    final s0 = math.max(0.62, minSize).clamp(0.0, 1.0), s1 = math.max(0.56, minSize).clamp(0.0, 1.0);
    return KenBurns(
      px: win.left / s.w,
      py: win.top / s.h,
      pw: win.width / s.w,
      ph: win.height / s.h,
      from: ShotRect((1 - s0) / 2 + 0.02, (1 - s0) / 2 - 0.04, s0),
      to: ShotRect((1 - s1) / 2 - 0.01, (1 - s1) / 2 - 0.05, s1),
      rotFrom: -1.2,
      rotTo: 1.2,
      linear: true,
    );
  }

  // ───────────────────────── Elaborazione foto ─────────────────────────

  /// Decodifica (rispettando EXIF) riducendo a [maxSide] px.
  static Future<ui.Image> _decode(String path, {int maxSide = 2200}) async {
    final bytes = await File(path).readAsBytes();
    final probe = (await (await ui.instantiateImageCodec(bytes)).getNextFrame()).image;
    final w = probe.width, h = probe.height;
    probe.dispose();
    final k = math.min(1.0, maxSide / math.max(w, h));
    return (await (await ui.instantiateImageCodec(bytes,
                targetWidth: (w * k).round(), targetHeight: (h * k).round()))
            .getNextFrame())
        .image;
  }

  static Future<Uint8List> _rgba(ui.Image img) async =>
      (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();

  static Future<ui.Image> _fromRgba(Uint8List rgba, int w, int h) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  static Future<void> _savePng(ui.Image img, String path) async {
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    await File(path).writeAsBytes(png!.buffer.asUint8List(), flush: true);
  }

  /// Foto macro in low-key: la pelle va al nero, metallo e oro restano.
  Future<_Still> _lowKey(String src, String out, ShotRole role) async {
    final img = await _decode(src);
    final w = img.width, h = img.height;
    final data = await _rgba(img);
    img.dispose();
    final res = await Isolate.run(() => gradePixels(data, w, h, lowKey: true));
    final graded = await _fromRgba(res, w, h);
    await _savePng(graded, out);
    graded.dispose();
    return _Still(out, w, h, role);
  }

  /// Orologio intero ritagliato su nero (solo Android: ML Kit Subject
  /// Segmentation). Restituisce null se non è possibile.
  Future<_Still?> _cutout(String src, String out, double a) async {
    if (!Platform.isAndroid) return null;
    try {
      final img = await _decode(src);
      final w = img.width, h = img.height;
      final data = await _rgba(img);
      final graded = await _fromRgba(await Isolate.run(() => gradePixels(data, w, h, lowKey: false)), w, h);
      img.dispose();

      // Segmentazione su una copia ridotta.
      const segMax = 1024;
      final k = math.min(1.0, segMax / math.max(w, h));
      final sw = (w * k).round(), sh = (h * k).round();
      final small = await _decode(src, maxSide: math.max(sw, sh));
      final tmp = p.join(p.dirname(out), 'seg_in.png');
      await _savePng(small, tmp);
      final mw = small.width, mh = small.height;
      small.dispose();
      final seg = SubjectSegmenter(
        options: SubjectSegmenterOptions(
          enableForegroundBitmap: false,
          enableForegroundConfidenceMask: true,
          enableMultipleSubjects: SubjectResultOptions(enableConfidenceMask: false, enableSubjectBitmap: false),
        ),
      );
      final result = await seg.processImage(InputImage.fromFilePath(tmp));
      await seg.close();
      final conf = result.foregroundConfidenceMask;
      if (conf == null || conf.length < mw * mh) return null;

      // Maschera (alfa) e riquadro dell'oggetto.
      final maskRgba = Uint8List(mw * mh * 4);
      var minX = mw, minY = mh, maxX = -1, maxY = -1, count = 0;
      for (var y = 0; y < mh; y++) {
        for (var x = 0; x < mw; x++) {
          final v = conf[y * mw + x];
          final i = (y * mw + x) * 4;
          maskRgba[i] = 255;
          maskRgba[i + 1] = 255;
          maskRgba[i + 2] = 255;
          maskRgba[i + 3] = (v.clamp(0.0, 1.0) * 255).round();
          if (v > 0.5) {
            count++;
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
          }
        }
      }
      if (count < mw * mh * 0.03) return null;
      final mask = await _fromRgba(maskRgba, mw, mh);
      final bx = minX / mw * w, by = minY / mh * h, bw = (maxX - minX) / mw * w, bh = (maxY - minY) / mh * h;

      // Tela nera con le proporzioni del video, oggetto centrato con margine.
      var cw = math.max(bw * 1.32, bh * 1.04 * a);
      var chh = cw / a;
      cw = cw.roundToDouble();
      chh = chh.roundToDouble();
      final ox = cw / 2 - (bx + bw / 2), oy = chh / 2 - (by + bh / 2);

      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      canvas.drawRect(Rect.fromLTWH(0, 0, cw, chh), Paint()..color = Colors.black);
      final imgRect = Rect.fromLTWH(ox, oy, w.toDouble(), h.toDouble());
      canvas.saveLayer(imgRect, Paint());
      canvas.drawImageRect(graded, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), imgRect,
          Paint()..filterQuality = FilterQuality.high);
      canvas.drawImageRect(mask, Rect.fromLTWH(0, 0, mw.toDouble(), mh.toDouble()), imgRect,
          Paint()
            ..blendMode = BlendMode.dstIn
            ..filterQuality = FilterQuality.high);
      // Sfuma il cinturino verso i bordi della foto (niente tagli netti).
      final fade = h * 0.1;
      canvas.drawRect(
        imgRect,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = ui.Gradient.linear(
            Offset(0, oy),
            Offset(0, oy + h),
            const [Color(0x00000000), Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
            [0, fade / h, 1 - fade / h, 1],
          ),
      );
      canvas.restore();
      final outImg = await rec.endRecording().toImage(cw.toInt(), chh.toInt());
      await _savePng(outImg, out);
      outImg.dispose();
      graded.dispose();
      mask.dispose();
      return _Still(out, cw.toInt(), chh.toInt(), ShotRole.hero, isCutout: true);
    } catch (_) {
      return null;
    }
  }

  static Future<String> _solid(String path) async {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 16, 16), Paint()..color = Colors.black);
    final img = await rec.endRecording().toImage(16, 16);
    await _savePng(img, path);
    img.dispose();
    return path;
  }
}

/// Correzione colore "da pubblicità" + nitidezza, su pixel RGBA.
/// [lowKey]: curva che porta al nero i toni medio-scuri (sfondo) lasciando
/// brillare i riflessi; altrimenti una curva neutra più contrastata.
Uint8List gradePixels(Uint8List src, int w, int h, {required bool lowKey}) {
  final List<(double, double)> pts = lowKey
      ? const [(0.0, 0.0), (0.30, 0.02), (0.5, 0.16), (0.72, 0.55), (0.9, 0.9), (1.0, 1.0)]
      : const [(0.0, 0.0), (0.15, 0.06), (0.5, 0.47), (0.85, 0.9), (1.0, 1.0)];
  final lut = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    final x = i / 255;
    var y = x;
    for (var k = 0; k + 1 < pts.length; k++) {
      final (x0, y0) = pts[k];
      final (x1, y1) = pts[k + 1];
      if (x >= x0 && x <= x1) {
        y = y0 + (y1 - y0) * (x - x0) / (x1 - x0);
        break;
      }
    }
    lut[i] = (y * 255).round().clamp(0, 255);
  }
  final sat = lowKey ? 0.85 : 0.92;
  final amount = lowKey ? 0.6 : 0.5;

  // Sfocatura a scatola (2 passate) per la maschera di contrasto.
  final n = w * h;
  final blur = Float32List(n * 3), tmp = Float32List(n * 3);
  for (var i = 0; i < n; i++) {
    blur[i * 3] = src[i * 4].toDouble();
    blur[i * 3 + 1] = src[i * 4 + 1].toDouble();
    blur[i * 3 + 2] = src[i * 4 + 2].toDouble();
  }
  const r = 2;
  for (var pass = 0; pass < 2; pass++) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var a = 0.0, b = 0.0, c = 0.0, cnt = 0;
        for (var d = -r; d <= r; d++) {
          final xx = (x + d).clamp(0, w - 1);
          final j = (y * w + xx) * 3;
          a += blur[j];
          b += blur[j + 1];
          c += blur[j + 2];
          cnt++;
        }
        final o = (y * w + x) * 3;
        tmp[o] = a / cnt;
        tmp[o + 1] = b / cnt;
        tmp[o + 2] = c / cnt;
      }
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var a = 0.0, b = 0.0, c = 0.0, cnt = 0;
        for (var d = -r; d <= r; d++) {
          final yy = (y + d).clamp(0, h - 1);
          final j = (yy * w + x) * 3;
          a += tmp[j];
          b += tmp[j + 1];
          c += tmp[j + 2];
          cnt++;
        }
        final o = (y * w + x) * 3;
        blur[o] = a / cnt;
        blur[o + 1] = b / cnt;
        blur[o + 2] = c / cnt;
      }
    }
  }

  final out = Uint8List(n * 4);
  for (var i = 0; i < n; i++) {
    final r0 = src[i * 4].toDouble(), g0 = src[i * 4 + 1].toDouble(), b0 = src[i * 4 + 2].toDouble();
    // nitidezza
    var rr = r0 + (r0 - blur[i * 3]) * amount;
    var gg = g0 + (g0 - blur[i * 3 + 1]) * amount;
    var bb = b0 + (b0 - blur[i * 3 + 2]) * amount;
    // desaturazione leggera
    final l = 0.299 * rr + 0.587 * gg + 0.114 * bb;
    rr = rr * sat + l * (1 - sat);
    gg = gg * sat + l * (1 - sat);
    bb = bb * sat + l * (1 - sat);
    out[i * 4] = lut[rr.round().clamp(0, 255)];
    out[i * 4 + 1] = lut[gg.round().clamp(0, 255)];
    out[i * 4 + 2] = lut[bb.round().clamp(0, 255)];
    out[i * 4 + 3] = 255;
  }
  return out;
}

/// Colonna sonora sintetica (WAV 44,1 kHz stereo): ticchettio nella parte
/// macro, colpi sui tagli, salita, silenzio, colpo basso sulla rivelazione,
/// scintillio, colpo finale sul marchio. Funzione pura (testabile).
void writeSpotSoundtrack(String path, double total, List<double> macroCuts, double blackCut, double heroCut,
    double endCut) {
  const sr = 44100;
  final n = (total * sr).round();
  final out = Float64List(n);
  final rng = math.Random(3);
  double noise() => rng.nextDouble() * 2 - 1;

  void add(List<double> sig, double at, double gain) {
    final i = (at * sr).round();
    for (var k = 0; k < sig.length && i + k < n; k++) {
      if (i + k >= 0) out[i + k] += sig[k] * gain;
    }
  }

  List<double> tick(double f, double dec, double dur) => [
        for (var k = 0; k < (dur * sr).round(); k++)
          (math.sin(2 * math.pi * f * k / sr) * 0.6 + noise() * 0.4) * math.exp(-(k / sr) / dec),
      ];
  List<double> boom(double f0, double dur) {
    final s = <double>[];
    var ph = 0.0;
    for (var k = 0; k < (dur * sr).round(); k++) {
      final t = k / sr;
      final f = f0 * (1 + 0.6 * math.exp(-t / 0.08));
      ph += 2 * math.pi * f / sr;
      s.add(math.sin(ph) * math.exp(-t / 0.9) + 0.25 * noise() * math.exp(-t / 0.03));
    }
    return s;
  }

  List<double> shimmer(double dur) => [
        for (var k = 0; k < (dur * sr).round(); k++)
          () {
            final t = k / sr;
            final v = math.sin(2 * math.pi * 1760 * t) * 0.3 +
                math.sin(2 * math.pi * 2637 * t + 1) * 0.2 +
                math.sin(2 * math.pi * 3520 * t + 2) * 0.12 +
                math.sin(2 * math.pi * 1318 * t + 3) * 0.25;
            return v * math.min(1.0, t / 0.4) * math.exp(-t / 1.6);
          }(),
      ];

  // Tappeto scuro.
  for (var k = 0; k < n; k++) {
    final t = k / sr;
    final pad = (math.sin(2 * math.pi * 55 * t) +
            0.6 * math.sin(2 * math.pi * 82.4 * t) +
            0.3 * math.sin(2 * math.pi * 110.2 * t)) *
        (0.6 + 0.4 * math.sin(2 * math.pi * 0.25 * t));
    final env = math.min(1.0, t / 2.0) * math.min(1.0, (total - t) / 1.5);
    out[k] += pad * env * 0.08;
  }
  // Ticchettio.
  for (var t = 0.0; t < blackCut - 0.05; t += 0.5) {
    add(tick(3200, 0.012, 0.05), t, (t * 2).round() % 2 == 0 ? 0.35 : 0.2);
  }
  for (final c in macroCuts) {
    add(tick(2400, 0.02, 0.08), c, 0.7);
  }
  // Salita prima della rivelazione, poi quasi silenzio.
  final riseStart = macroCuts.isEmpty ? blackCut - 0.7 : macroCuts.last;
  final riseLen = ((blackCut - riseStart) * sr).round();
  for (var k = 0; k < riseLen; k++) {
    final i = (riseStart * sr).round() + k;
    if (i >= 0 && i < n) out[i] += noise() * math.pow(k / math.max(1, riseLen), 2.5) * 0.25;
  }
  for (var k = (blackCut * sr).round(); k < (heroCut * sr).round() && k < n; k++) {
    out[k] *= 0.15;
  }
  add(boom(48, 2.5), heroCut, 0.9);
  add(shimmer(3.5), heroCut + 0.1, 0.25);
  add(boom(40, 3.0), endCut, 0.7);
  add(shimmer(3.0), endCut + 0.2, 0.3);

  // Saturazione morbida, normalizzazione, dissolvenza finale.
  var peak = 1e-9;
  for (var k = 0; k < n; k++) {
    out[k] = _tanh(out[k] * 1.2);
    if (out[k].abs() > peak) peak = out[k].abs();
  }
  final bytes = BytesBuilder();
  final header = ByteData(44);
  final dataLen = n * 4;
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      header.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  header.setUint32(4, 36 + dataLen, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 2, Endian.little);
  header.setUint32(24, sr, Endian.little);
  header.setUint32(28, sr * 4, Endian.little);
  header.setUint16(32, 4, Endian.little);
  header.setUint16(34, 16, Endian.little);
  str(36, 'data');
  header.setUint32(40, dataLen, Endian.little);
  bytes.add(header.buffer.asUint8List());
  final pcm = ByteData(dataLen);
  final delay = (0.012 * sr).round();
  for (var k = 0; k < n; k++) {
    final fade = math.min(1.0, (total - k / sr) / 0.8);
    final l = out[k] / peak * 0.85 * fade;
    final r = (k >= delay ? out[k - delay] : 0.0) / peak * 0.85 * 0.9 * fade;
    pcm.setInt16(k * 4, (l * 32767).round().clamp(-32768, 32767), Endian.little);
    pcm.setInt16(k * 4 + 2, (r * 32767).round().clamp(-32768, 32767), Endian.little);
  }
  bytes.add(pcm.buffer.asUint8List());
  File(path).writeAsBytesSync(bytes.toBytes(), flush: true);
}

double _tanh(double x) {
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}
