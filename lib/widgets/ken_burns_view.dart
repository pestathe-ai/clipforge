import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/project.dart';

/// Anteprima del movimento di camera su una foto (stessa geometria dell'export).
class KenBurnsView extends StatefulWidget {
  const KenBurnsView({super.key, required this.path, required this.motion, required this.progress});
  final String path;
  final KenBurns motion;

  /// Avanzamento della clip (0–1).
  final double progress;

  @override
  State<KenBurnsView> createState() => _KenBurnsViewState();
}

class _KenBurnsViewState extends State<KenBurnsView> {
  static final _cache = <String, ui.Image>{};
  ui.Image? _img;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant KenBurnsView old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _load();
  }

  Future<void> _load() async {
    final cached = _cache[widget.path];
    if (cached != null) {
      setState(() => _img = cached);
      return;
    }
    final bytes = await File(widget.path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 2000);
    final img = (await codec.getNextFrame()).image;
    if (_cache.length > 12) _cache.remove(_cache.keys.first);
    _cache[widget.path] = img;
    if (mounted) setState(() => _img = img);
  }

  @override
  Widget build(BuildContext context) {
    final img = _img;
    if (img == null) return const ColoredBox(color: Colors.black);
    return CustomPaint(painter: _KbPainter(img, widget.motion, widget.progress), size: Size.infinite);
  }
}

class _KbPainter extends CustomPainter {
  _KbPainter(this.img, this.kb, this.p);
  final ui.Image img;
  final KenBurns kb;
  final double p;

  @override
  void paint(Canvas canvas, Size size) {
    final iw = img.width.toDouble(), ih = img.height.toDouble();
    final box = Rect.fromLTWH(kb.px * iw, kb.py * ih, kb.pw * iw, kb.ph * ih);
    final r = kb.at(p);
    final src = Rect.fromLTWH(
      box.left + r.x * box.width,
      box.top + r.y * box.height,
      r.size * box.width,
      r.size * box.height,
    );
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    canvas.save();
    final rot = kb.rotationAt(p) * math.pi / 180;
    final over = kb.rotates ? 1.12 : 1.0;
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(rot);
    final dst = Rect.fromCenter(center: Offset.zero, width: size.width * over, height: size.height * over);
    canvas.drawImageRect(img, src, dst, Paint()..filterQuality = FilterQuality.high);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _KbPainter old) => old.p != p || old.img != img || old.kb != kb;
}
