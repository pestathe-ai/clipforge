import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/project.dart';

/// Forma di una maschera dentro il rettangolo [r].
/// Usata sia per l'anteprima (ClipPath) che per il PNG dell'export.
Path maskPath(MaskShape shape, Rect r) {
  switch (shape) {
    case MaskShape.none:
      return Path()..addRect(r);
    case MaskShape.circle:
      return Path()..addOval(r);
    case MaskShape.rounded:
      return Path()
        ..addRRect(RRect.fromRectAndRadius(r, Radius.circular(r.shortestSide * 0.14)));
    case MaskShape.diamond:
      return Path()
        ..moveTo(r.center.dx, r.top)
        ..lineTo(r.right, r.center.dy)
        ..lineTo(r.center.dx, r.bottom)
        ..lineTo(r.left, r.center.dy)
        ..close();
    case MaskShape.heart:
      final w = r.width, h = r.height;
      Offset pt(double x, double y) => Offset(r.left + x * w, r.top + y * h);
      return Path()
        ..moveTo(pt(0.5, 0.95).dx, pt(0.5, 0.95).dy)
        ..cubicTo(pt(0.1, 0.65).dx, pt(0.1, 0.65).dy, pt(-0.05, 0.3).dx, pt(-0.05, 0.3).dy,
            pt(0.25, 0.1).dx, pt(0.25, 0.1).dy)
        ..cubicTo(pt(0.38, 0.02).dx, pt(0.38, 0.02).dy, pt(0.48, 0.1).dx, pt(0.48, 0.1).dy,
            pt(0.5, 0.2).dx, pt(0.5, 0.2).dy)
        ..cubicTo(pt(0.52, 0.1).dx, pt(0.52, 0.1).dy, pt(0.62, 0.02).dx, pt(0.62, 0.02).dy,
            pt(0.75, 0.1).dx, pt(0.75, 0.1).dy)
        ..cubicTo(pt(1.05, 0.3).dx, pt(1.05, 0.3).dy, pt(0.9, 0.65).dx, pt(0.9, 0.65).dy,
            pt(0.5, 0.95).dx, pt(0.5, 0.95).dy)
        ..close();
    case MaskShape.star:
      final path = Path();
      final c = r.center;
      for (var i = 0; i < 10; i++) {
        final a = -math.pi / 2 + i * math.pi / 5;
        final k = i.isEven ? 1.0 : 0.45;
        final p = Offset(c.dx + math.cos(a) * r.width / 2 * k, c.dy + math.sin(a) * r.height / 2 * k);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      return path..close();
  }
}

/// PNG della maschera: bianco = visibile, nero = trasparente.
Future<void> writeMaskPng(MaskShape shape, int w, int h, String path) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  canvas.drawRect(rect, Paint()..color = Colors.black);
  canvas.drawPath(maskPath(shape, rect), Paint()..color = Colors.white..isAntiAlias = true);
  final image = await recorder.endRecording().toImage(w, h);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  await File(path).writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
}

class MaskClipper extends CustomClipper<Path> {
  MaskClipper(this.shape);
  final MaskShape shape;
  @override
  Path getClip(Size size) => maskPath(shape, Offset.zero & size);
  @override
  bool shouldReclip(covariant MaskClipper old) => old.shape != shape;
}
