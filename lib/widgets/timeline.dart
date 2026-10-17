import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/project.dart';

enum SelectionKind { none, clip, text, music }

class Selection {
  const Selection(this.kind, [this.index = -1]);
  const Selection.none() : this(SelectionKind.none);
  final SelectionKind kind;
  final int index;

  bool isClip(int i) => kind == SelectionKind.clip && index == i;
  bool isText(int i) => kind == SelectionKind.text && index == i;
  bool get isMusic => kind == SelectionKind.music;
}

/// Timeline a tre tracce: video, testi, musica. Tocca un punto vuoto per
/// spostare la testina, tocca un blocco per selezionarlo.
class Timeline extends StatelessWidget {
  const Timeline({
    super.key,
    required this.project,
    required this.position,
    required this.selection,
    required this.onSeek,
    required this.onSelect,
    this.pixelsPerSecond = 56,
  });

  final Project project;
  final Duration position;
  final Selection selection;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<Selection> onSelect;
  final double pixelsPerSecond;

  static const _lead = 24.0;
  static const _videoH = 56.0;
  static const _trackH = 30.0;
  static const _gap = 6.0;

  double _px(Duration d) => d.inMicroseconds / 1e6 * pixelsPerSecond;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final total = project.totalDuration;
    final screenW = MediaQuery.sizeOf(context).width;
    final contentW = _px(total) + _lead + screenW * 0.5;
    const height = 18 + _videoH + _gap + _trackH + _gap + _trackH;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) {
          final s = ((d.localPosition.dx - _lead) / pixelsPerSecond)
              .clamp(0.0, total.inMicroseconds / 1e6);
          onSeek(Duration(microseconds: (s * 1e6).round()));
          onSelect(const Selection.none());
        },
        child: SizedBox(
          width: contentW,
          height: height,
          child: Stack(
            children: [
              // Righello dei secondi.
              for (var s = 0; s <= total.inSeconds; s++)
                Positioned(
                  left: _lead + s * pixelsPerSecond - 6,
                  top: 0,
                  child: Text(
                    s % 5 == 0 ? '${s}s' : '·',
                    style: const TextStyle(fontSize: 10, color: Colors.white38),
                  ),
                ),

              // Traccia video.
              ..._clipBlocks(accent),

              // Traccia testi.
              for (var i = 0; i < project.texts.length; i++)
                _block(
                  left: _lead + _px(project.texts[i].start),
                  top: 18 + _videoH + _gap,
                  width: _px(project.texts[i].end - project.texts[i].start),
                  height: _trackH,
                  color: const Color(0xFFB98CFF),
                  selected: selection.isText(i),
                  label: 'T  ${project.texts[i].text}',
                  onTap: () => onSelect(Selection(SelectionKind.text, i)),
                ),

              // Traccia musica.
              if (project.music != null)
                _block(
                  left: _lead,
                  top: 18 + _videoH + _gap * 2 + _trackH,
                  width: _px(total),
                  height: _trackH,
                  color: const Color(0xFFFFB547),
                  selected: selection.isMusic,
                  label: '♪  ${p.basename(project.music!.path)}',
                  onTap: () => onSelect(const Selection(SelectionKind.music)),
                ),

              // Testina.
              Positioned(
                left: _lead + _px(position) - 1,
                top: 14,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(width: 2, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _clipBlocks(Color accent) {
    final widgets = <Widget>[];
    var left = _lead;
    for (var i = 0; i < project.clips.length; i++) {
      final c = project.clips[i];
      final w = _px(c.outputDuration);
      final extras = [
        if (c.speed != 1.0) '${c.speed}x',
        if (c.filter != VideoFilter.none) c.filter.label,
      ].join(' · ');
      widgets.add(_block(
        left: left,
        top: 18,
        width: w,
        height: _videoH,
        color: accent.withValues(alpha: 0.75),
        selected: selection.isClip(i),
        label: 'Clip ${i + 1}${extras.isEmpty ? '' : '\n$extras'}',
        dark: true,
        onTap: () => onSelect(Selection(SelectionKind.clip, i)),
      ));
      left += w;
    }
    return widgets;
  }

  Widget _block({
    required double left,
    required double top,
    required double width,
    required double height,
    required Color color,
    required bool selected,
    required String label,
    required VoidCallback onTap,
    bool dark = false,
  }) {
    return Positioned(
      left: left,
      top: top,
      width: width < 8 ? 8 : width,
      height: height,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(right: 2),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? Colors.white : Colors.transparent,
              width: 2,
            ),
          ),
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: dark ? Colors.black87 : Colors.black,
            ),
          ),
        ),
      ),
    );
  }
}
