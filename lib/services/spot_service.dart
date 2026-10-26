import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/project.dart';

enum SpotStyle {
  luxury('Lusso scuro', 'Luci calde, dissolvenze al nero, testi oro'),
  sport('Sportivo', 'Ritmo veloce, zoom e flash'),
  minimal('Minimal', 'Pulito, luminoso, testi semplici');

  const SpotStyle(this.label, this.description);
  final String label;
  final String description;
}

class SpotOptions {
  const SpotOptions({
    required this.title,
    this.subtitle = '',
    this.endText = '',
    this.style = SpotStyle.luxury,
    this.seconds = 20,
    this.aspect = AspectRatioPreset.portrait,
  });
  final String title;
  final String subtitle;
  final String endText;
  final SpotStyle style;
  final int seconds;
  final AspectRatioPreset aspect;
}

/// Foto preparata: orientata correttamente, con soggetto e dettagli trovati.
class _Photo {
  _Photo(this.path, this.w, this.h, this.subject, this.details);
  final String path;
  final int w, h;

  /// Riquadro del soggetto in pixel (x, y, w, h).
  final Rect subject;

  /// Centri e dimensioni (lato in pixel) dei dettagli più ricchi.
  final List<(Offset, double)> details;
}

/// Crea uno "spot prodotto" (stile pubblicità) partendo da foto:
/// trova l'oggetto e i suoi dettagli e costruisce inquadrature con zoom
/// macro, carrellate, leggere rotazioni e riflessi di luce.
class SpotService {
  Future<Project> build(
    List<String> photos,
    SpotOptions o, {
    void Function(String phase, double progress)? onProgress,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'media', 'spot_${DateTime.now().millisecondsSinceEpoch}'));
    await dir.create(recursive: true);

    final prepared = <_Photo>[];
    for (var i = 0; i < photos.length; i++) {
      onProgress?.call('Analizzo la foto ${i + 1} di ${photos.length}', i / (photos.length + 1));
      final ph = await _prepare(photos[i], p.join(dir.path, 'foto_$i.png'));
      if (ph != null) prepared.add(ph);
    }
    if (prepared.isEmpty) throw StateError('Nessuna foto leggibile');
    onProgress?.call('Preparo le inquadrature', 0.9);
    final glint = await _renderGlint(p.join(dir.path, 'riflesso.png'));
    final project = _direct(prepared, o, glint);
    onProgress?.call('Fatto', 1);
    return project;
  }

  // ───────────────────────── Preparazione e analisi ─────────────────────────

  /// Decodifica la foto (rispettando l'orientamento EXIF), la riduce a
  /// 3000 px sul lato lungo e la salva in PNG; poi cerca soggetto e dettagli.
  Future<_Photo?> _prepare(String src, String out) async {
    try {
      final bytes = await File(src).readAsBytes();
      final probe = await ui.instantiateImageCodec(bytes);
      final first = await probe.getNextFrame();
      final ow = first.image.width, oh = first.image.height;
      first.image.dispose();
      const maxSide = 3000;
      final k = math.min(1.0, maxSide / math.max(ow, oh));
      final codec = await ui.instantiateImageCodec(bytes,
          targetWidth: (ow * k).round(), targetHeight: (oh * k).round());
      final img = (await codec.getNextFrame()).image;
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      await File(out).writeAsBytes(png!.buffer.asUint8List(), flush: true);
      final w = img.width, h = img.height;
      img.dispose();

      // Versione piccola per l'analisi.
      const aw = 256;
      final ah = math.max(8, (aw * h / w).round());
      final small = await ui.instantiateImageCodec(bytes, targetWidth: aw, targetHeight: ah);
      final simg = (await small.getNextFrame()).image;
      final rgba = await simg.toByteData(format: ui.ImageByteFormat.rawRgba);
      simg.dispose();
      final data = rgba!.buffer.asUint8List();
      final res = await Isolate.run(() => analyzePhoto(data, aw, ah));

      final sx = w / aw, sy = h / ah;
      final subject = Rect.fromLTWH(res[0] * sx, res[1] * sy, res[2] * sx, res[3] * sy);
      final details = <(Offset, double)>[];
      for (var i = 4; i + 2 < res.length; i += 3) {
        details.add((Offset(res[i] * sx, res[i + 1] * sy), res[i + 2] * sx));
      }
      return _Photo(out, w, h, subject, details);
    } catch (_) {
      return null;
    }
  }

  // ───────────────────────── Regia ─────────────────────────

  Project _direct(List<_Photo> photos, SpotOptions o, (String, int, int) glint) {
    final project = Project(aspect: o.aspect)
      ..background = CanvasBackground.black
      ..fps = 30;
    final a = project.aspect.width / project.aspect.height; // proporzioni del video
    final style = o.style;
    final macroDur = switch (style) { SpotStyle.sport => 1.4, SpotStyle.luxury => 2.2, SpotStyle.minimal => 2.0 };
    final wideDur = switch (style) { SpotStyle.sport => 1.8, SpotStyle.luxury => 2.8, SpotStyle.minimal => 2.5 };
    final rot = switch (style) { SpotStyle.sport => 3.0, SpotStyle.luxury => 1.5, SpotStyle.minimal => 0.0 };
    final transitions = switch (style) {
      SpotStyle.luxury => [TransitionType.fade, TransitionType.fadeBlack],
      SpotStyle.sport => [TransitionType.zoom, TransitionType.slideLeft, TransitionType.fadeWhite],
      SpotStyle.minimal => [TransitionType.fade],
    };
    final trDur = Duration(milliseconds: style == SpotStyle.sport ? 300 : 550);
    final adjust = switch (style) {
      SpotStyle.luxury => const ColorAdjust(contrast: 1.15, saturation: 1.05, warmth: 0.25, sharpen: 0.5),
      SpotStyle.sport => const ColorAdjust(contrast: 1.25, saturation: 1.2, sharpen: 0.6),
      SpotStyle.minimal => const ColorAdjust(brightness: 0.04, contrast: 1.05, saturation: 0.95, sharpen: 0.4),
    };

    // Pianificazione: apertura, macro sui dettagli di ogni foto, chiusura.
    final shots = <(_Photo, KenBurns, double, bool)>[]; // foto, movimento, durata, riflesso
    final budget = o.seconds.toDouble();
    shots.add((photos[0], _wide(photos[0], a, rot, pushIn: true), wideDur, true));
    var used = wideDur + wideDur + 0.5; // apertura + chiusura
    var round = 0;
    var added = true;
    while (added && used < budget) {
      added = false;
      for (final ph in photos) {
        final hasDetail = round < ph.details.length;
        final dur = hasDetail ? macroDur : wideDur;
        if (used + dur > budget) break;
        if (hasDetail) {
          shots.add((ph, _macro(ph, ph.details[round], a, rot, flip: shots.length.isOdd), macroDur, false));
        } else if (round == ph.details.length && !identical(ph, photos[0])) {
          shots.add((ph, _wide(ph, a, rot, pushIn: shots.length.isEven), wideDur, true));
        } else {
          continue;
        }
        used += dur;
        added = true;
      }
      round++;
      if (round > 6) break;
    }
    // Chiusura: dal dettaglio migliore all'oggetto intero.
    final hero = photos[0];
    shots.add((hero, _reveal(hero, a, rot), wideDur + 0.5, true));

    // Clip.
    for (var i = 0; i < shots.length; i++) {
      final (ph, kb, dur, _) = shots[i];
      final d = Duration(milliseconds: (dur * 1000).round());
      project.clips.add(VideoClip.image(ph.path, duration: d)
        ..width = ph.w
        ..height = ph.h
        ..motion = kb
        ..effect = style == SpotStyle.minimal ? ClipEffect.none : ClipEffect.vignette
        ..adjust = adjust
        ..transition = i == shots.length - 1 ? TransitionType.none : transitions[i % transitions.length]
        ..transitionDuration = trDur);
    }
    // Inizi reali sulla timeline (le transizioni sovrappongono le clip).
    final starts = [for (var i = 0; i < shots.length; i++) project.startOf(i)];
    final total = project.totalDuration;

    // Riflessi di luce sulle inquadrature intere.
    final (gPath, gw, gh) = glint;
    for (var i = 0; i < shots.length; i++) {
      if (!shots[i].$4) continue;
      final s = starts[i] + const Duration(milliseconds: 500);
      const len = Duration(milliseconds: 1100);
      if (s + len > total) continue;
      project.pips.add(PipLayer(
        path: gPath,
        isImage: true,
        sourceDuration: const Duration(minutes: 10),
        width: gw,
        height: gh,
        hasAudio: false,
        start: s,
        trimEnd: len,
        cx: -0.35,
        toCx: 1.35,
        cy: 0.5,
        toCy: 0.5,
        scale: 0.8,
        opacity: style == SpotStyle.minimal ? 0.35 : 0.5,
      ));
    }

    // Testi.
    const gold = Color(0xFFE6C77A);
    final titleColor = switch (style) { SpotStyle.luxury => gold, SpotStyle.sport => Colors.white, SpotStyle.minimal => Colors.white };
    String up(String s) => style == SpotStyle.minimal ? s : s.toUpperCase();
    final introEnd = starts.length > 1 ? starts[1] : total;
    if (o.title.trim().isNotEmpty) {
      project.overlays.add(VideoOverlay(
        kind: OverlayKind.text,
        text: up(o.title.trim()),
        start: const Duration(milliseconds: 500),
        end: introEnd,
        color: titleColor,
        fontSize: style == SpotStyle.sport ? 110 : 92,
        outline: style == SpotStyle.sport,
        box: style == SpotStyle.minimal,
        boxColor: const Color(0x66000000),
        cy: 0.8,
        animIn: style == SpotStyle.sport ? AnimIn.slideLeft : AnimIn.slideUp,
        animOut: AnimOut.fade,
      ));
    }
    if (o.subtitle.trim().isNotEmpty) {
      project.overlays.add(VideoOverlay(
        kind: OverlayKind.text,
        text: o.subtitle.trim(),
        start: const Duration(milliseconds: 900),
        end: introEnd,
        color: Colors.white,
        fontSize: 52,
        outline: false,
        cy: 0.87,
        animIn: AnimIn.fade,
        animOut: AnimOut.fade,
      ));
    }
    final outroStart = starts.last + const Duration(milliseconds: 800);
    final finalText = [o.title.trim(), o.endText.trim()].where((s) => s.isNotEmpty).join('\n');
    if (finalText.isNotEmpty && outroStart < total) {
      project.overlays.add(VideoOverlay(
        kind: OverlayKind.text,
        text: up(finalText),
        start: outroStart,
        end: total,
        color: titleColor,
        fontSize: 84,
        outline: style != SpotStyle.minimal,
        box: style == SpotStyle.minimal,
        boxColor: const Color(0x66000000),
        cy: 0.8,
        animIn: AnimIn.fade,
        animOut: AnimOut.none,
      ));
    }
    return project;
  }

  /// Inquadratura intera dell'oggetto, con lieve avvicinamento.
  KenBurns _wide(_Photo ph, double a, double rot, {required bool pushIn}) {
    final s = ph.subject;
    final wide = math.max(s.width * 1.35, s.height * 1.35 * a);
    final r1 = _fit(ph, s.center, wide, a);
    final r2 = _fit(ph, s.center, wide * 0.84, a);
    return _make(ph, pushIn ? r1 : r2, pushIn ? r2 : r1, a, pushIn ? -rot / 2 : rot / 2, pushIn ? rot / 2 : -rot / 2);
  }

  /// Macro su un dettaglio, con carrellata laterale.
  KenBurns _macro(_Photo ph, (Offset, double) d, double a, double rot, {required bool flip}) {
    final (c, size) = d;
    // Non ingrandire oltre ~3 volte i pixel reali (diventerebbe sgranato).
    final minW = math.max(ph.w * 0.12, 1080 / 3);
    final base = math.max(size * 1.6, minW);
    final shift = base * 0.14 * (flip ? -1 : 1);
    final r1 = _fit(ph, c.translate(-shift, 0), base * 1.12, a);
    final r2 = _fit(ph, c.translate(shift, 0), base, a);
    return _make(ph, r1, r2, a, flip ? rot : -rot, flip ? -rot : rot);
  }

  /// Dal dettaglio migliore all'oggetto intero (chiusura).
  KenBurns _reveal(_Photo ph, double a, double rot) {
    final s = ph.subject;
    final wide = math.max(s.width * 1.4, s.height * 1.4 * a);
    final d = ph.details.isNotEmpty ? ph.details.first : (s.center, s.shortestSide * 0.3);
    final minW = math.max(ph.w * 0.12, 1080 / 3);
    final r1 = _fit(ph, d.$1, math.max(d.$2 * 1.8, minW), a);
    final r2 = _fit(ph, s.center, wide, a);
    return _make(ph, r1, r2, a, rot, 0);
  }

  /// Rettangolo con le proporzioni del video, centrato e tenuto dentro la foto.
  Rect _fit(_Photo ph, Offset c, double width, double a) {
    final w = math.min(width, math.min(ph.w.toDouble(), ph.h * a));
    final h = w / a;
    final x = (c.dx - w / 2).clamp(0.0, ph.w - w);
    final y = (c.dy - h / 2).clamp(0.0, ph.h - h);
    return Rect.fromLTWH(x, y, w, h);
  }

  /// Riquadro comune alle due inquadrature + coordinate relative.
  KenBurns _make(_Photo ph, Rect r1, Rect r2, double a, double rotFrom, double rotTo) {
    final u = r1.expandToInclude(r2);
    final box = _fit(ph, u.center, math.max(u.width, u.height * a), a);
    ShotRect rel(Rect r) {
      final size = (r.width / box.width).clamp(0.05, 1.0);
      final x = ((r.left - box.left) / box.width).clamp(0.0, 1 - size);
      final y = ((r.top - box.top) / box.height).clamp(0.0, 1 - size);
      return ShotRect(x, y, size);
    }

    return KenBurns(
      px: box.left / ph.w,
      py: box.top / ph.h,
      pw: box.width / ph.w,
      ph: box.height / ph.h,
      from: rel(r1),
      to: rel(r2),
      rotFrom: rotFrom,
      rotTo: rotTo,
    );
  }

  /// Fascia di luce diagonale trasparente (il "riflesso" che scorre).
  Future<(String, int, int)> _renderGlint(String path) async {
    const w = 600, h = 1800;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.translate(w / 2, h / 2);
    canvas.rotate(0.35);
    const band = Rect.fromLTWH(-140, -1200, 280, 2400);
    canvas.drawRect(
      band,
      Paint()
        ..shader = const LinearGradient(colors: [
          Color(0x00FFFFFF),
          Color(0x40FFFFFF),
          Color(0xCCFFFFFF),
          Color(0x40FFFFFF),
          Color(0x00FFFFFF),
        ], stops: [0, 0.35, 0.5, 0.65, 1])
            .createShader(band),
    );
    final img = await rec.endRecording().toImage(w, h);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    await File(path).writeAsBytes(png!.buffer.asUint8List(), flush: true);
    return (path, w, h);
  }
}

/// Analisi della foto ridotta (RGBA): restituisce
/// [sx, sy, sw, sh, d1x, d1y, d1size, d2x, ...] in pixel della foto ridotta.
/// Soggetto = zona diversa dallo sfondo (colore dei bordi) o ricca di bordi;
/// dettagli = finestre con più contrasto locale (lancette, indici, logo...).
List<double> analyzePhoto(Uint8List rgba, int w, int h) {
  final n = w * h;
  final gray = Float64List(n);
  for (var i = 0; i < n; i++) {
    gray[i] = 0.299 * rgba[i * 4] + 0.587 * rgba[i * 4 + 1] + 0.114 * rgba[i * 4 + 2];
  }
  // Colore dello sfondo: media dei bordi.
  var br = 0.0, bg = 0.0, bb = 0.0, bc = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (x > 3 && x < w - 4 && y > 3 && y < h - 4) continue;
      final i = (y * w + x) * 4;
      br += rgba[i];
      bg += rgba[i + 1];
      bb += rgba[i + 2];
      bc++;
    }
  }
  br /= bc;
  bg /= bc;
  bb /= bc;

  // Gradiente (Sobel).
  final grad = Float64List(n);
  var gmax = 1.0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      double g(int dx, int dy) => gray[(y + dy) * w + x + dx];
      final gx = -g(-1, -1) - 2 * g(-1, 0) - g(-1, 1) + g(1, -1) + 2 * g(1, 0) + g(1, 1);
      final gy = -g(-1, -1) - 2 * g(0, -1) - g(1, -1) + g(-1, 1) + 2 * g(0, 1) + g(1, 1);
      final m = math.sqrt(gx * gx + gy * gy);
      grad[y * w + x] = m;
      if (m > gmax) gmax = m;
    }
  }

  // Soggetto.
  final xs = <int>[], ys = <int>[];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      final dr = rgba[i * 4] - br, dg = rgba[i * 4 + 1] - bg, db = rgba[i * 4 + 2] - bb;
      final diff = math.sqrt(dr * dr + dg * dg + db * db) / 441;
      if (diff > 0.16 || grad[i] / gmax > 0.3) {
        xs.add(x);
        ys.add(y);
      }
    }
  }
  double sx = 0, sy = 0, sw = w.toDouble(), sh = h.toDouble();
  if (xs.length > n * 0.02) {
    xs.sort();
    ys.sort();
    double pct(List<int> v, double q) => v[(q * (v.length - 1)).round()].toDouble();
    sx = pct(xs, 0.03);
    final ex = pct(xs, 0.97);
    sy = pct(ys, 0.03);
    final ey = pct(ys, 0.97);
    sw = math.max(8, ex - sx);
    sh = math.max(8, ey - sy);
  }

  // Immagine integrale del gradiente.
  final integ = Float64List((w + 1) * (h + 1));
  for (var y = 0; y < h; y++) {
    var row = 0.0;
    for (var x = 0; x < w; x++) {
      row += grad[y * w + x];
      integ[(y + 1) * (w + 1) + x + 1] = integ[y * (w + 1) + x + 1] + row;
    }
  }
  double sum(int x0, int y0, int x1, int y1) =>
      integ[y1 * (w + 1) + x1] - integ[y0 * (w + 1) + x1] - integ[y1 * (w + 1) + x0] + integ[y0 * (w + 1) + x0];

  // Dettagli: finestre quadrate dentro il soggetto, con soppressione dei vicini.
  final out = <double>[sx, sy, sw, sh];
  final cands = <(double, double, double, double)>[]; // punteggio, cx, cy, lato
  for (final f in [0.22, 0.3]) {
    final win = math.max(8, (math.min(sw, sh) * f).round());
    final step = math.max(2, win ~/ 5);
    for (var y = sy.round(); y + win <= (sy + sh).round() && y + win < h; y += step) {
      for (var x = sx.round(); x + win <= (sx + sw).round() && x + win < w; x += step) {
        final s = sum(x, y, x + win, y + win) / (win * win);
        cands.add((s, x + win / 2, y + win / 2, win.toDouble()));
      }
    }
  }
  cands.sort((a, b) => b.$1.compareTo(a.$1));
  final picked = <(double, double, double, double)>[];
  for (final c in cands) {
    if (picked.length >= 3) break;
    final far = picked.every((p) {
      final d = math.sqrt(math.pow(p.$2 - c.$2, 2) + math.pow(p.$3 - c.$3, 2));
      return d > math.max(p.$4, c.$4) * 0.9;
    });
    if (far) picked.add(c);
  }
  for (final c in picked) {
    out.addAll([c.$2, c.$3, c.$4]);
  }
  return out;
}
