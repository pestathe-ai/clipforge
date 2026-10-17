import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/project.dart';

/// Disegna un [VideoOverlay]. La stessa funzione serve all'anteprima
/// (CustomPaint, scala ridotta) e all'export (PNG a piena risoluzione),
/// così testi e sticker escono identici a come li vedi.
class OverlayLayout {
  OverlayLayout._(this.overlay, this.scale, this.fill, this.stroke, this.pad,
      this.boxSize);

  final VideoOverlay overlay;
  final double scale;
  final TextPainter fill;
  final TextPainter? stroke;
  final double pad;

  /// Dimensione del contenuto non ruotato.
  final Size boxSize;

  /// Dimensione del rettangolo che contiene il contenuto ruotato.
  Size get size {
    final a = overlay.rotation;
    final c = math.cos(a).abs(), s = math.sin(a).abs();
    return Size(
      (boxSize.width * c + boxSize.height * s).ceilToDouble(),
      (boxSize.width * s + boxSize.height * c).ceilToDouble(),
    );
  }

  /// [frameWidth] è la larghezza del video finale in pixel (per l'a capo).
  factory OverlayLayout(VideoOverlay o, {required double scale, required int frameWidth}) {
    final isSticker = o.kind == OverlayKind.sticker;
    final fontSize = o.fontSize * scale;
    final maxWidth = frameWidth * scale * (isSticker ? 1.0 : 0.88);
    final base = TextStyle(
      fontFamily: isSticker ? null : 'Poppins',
      fontWeight: FontWeight.w700,
      fontSize: fontSize,
      height: 1.15,
    );

    final fill = TextPainter(
      text: TextSpan(text: o.text, style: base.copyWith(color: o.color)),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);

    TextPainter? stroke;
    if (o.outline && !isSticker) {
      stroke = TextPainter(
        text: TextSpan(
          text: o.text,
          style: base.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = math.max(2, fontSize * 0.12)
              ..strokeJoin = StrokeJoin.round
              ..color = const Color(0xE6000000),
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxWidth);
    }

    final pad = (o.box ? 0.35 : 0.15) * fontSize;
    final box = Size(fill.width + pad * 2, fill.height + pad * 2);
    return OverlayLayout._(o, scale, fill, stroke, pad, box);
  }

  /// Disegna centrato in [center].
  void paint(Canvas canvas, Offset center, {double opacity = 1}) {
    if (opacity <= 0) return;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(overlay.rotation);
    canvas.translate(-boxSize.width / 2, -boxSize.height / 2);
    if (opacity < 1) {
      canvas.saveLayer(Offset.zero & boxSize,
          Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
    }
    if (overlay.box) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Offset.zero & boxSize, Radius.circular(overlay.fontSize * scale * 0.25)),
        Paint()..color = overlay.boxColor,
      );
    }
    final at = Offset(pad, pad);
    stroke?.paint(canvas, at);
    fill.paint(canvas, at);
    if (opacity < 1) canvas.restore();
    canvas.restore();
  }

  /// Renderizza come PNG trasparente a piena risoluzione.
  Future<(int, int)> writePng(String path) async {
    final s = size;
    final w = math.max(2, s.width.ceil() + (s.width.ceil() & 1));
    final h = math.max(2, s.height.ceil() + (s.height.ceil() & 1));
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    paint(canvas, Offset(w / 2, h / 2));
    final image = await recorder.endRecording().toImage(w, h);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File(path).writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
    return (w, h);
  }
}

/// Anteprima di tutti gli overlay visibili all'istante [time].
class OverlaysPainter extends CustomPainter {
  OverlaysPainter({
    required this.overlays,
    required this.time,
    required this.frameWidth,
    this.selected,
  });

  final List<VideoOverlay> overlays;
  final Duration time;
  final int frameWidth;
  final VideoOverlay? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / frameWidth;
    final t = time.inMicroseconds / 1e6;
    for (final o in overlays) {
      if (!o.visibleAt(time)) continue;
      final a = o.animAt(t);
      final layout = OverlayLayout(o, scale: scale, frameWidth: frameWidth);
      final base = o.centerAt(time);
      final center = Offset(
        (base.dx + a.dx) * size.width,
        (base.dy + a.dy) * size.height,
      );
      layout.paint(canvas, center, opacity: a.opacity);
      if (identical(o, selected)) {
        final r = Rect.fromCenter(
            center: center,
            width: layout.size.width + 8,
            height: layout.size.height + 8);
        canvas.drawRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = Colors.white,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant OverlaysPainter old) => true;
}
