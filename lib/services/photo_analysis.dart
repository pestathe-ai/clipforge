import 'dart:math' as math;
import 'dart:typed_data';

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
