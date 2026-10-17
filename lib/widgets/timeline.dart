import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/project.dart';

enum SelectionKind { none, clip, overlay, music, transition, pip, audio }

class Selection {
  const Selection(this.kind, [this.index = -1]);
  const Selection.none() : this(SelectionKind.none);
  final SelectionKind kind;
  final int index;

  bool isClip(int i) => kind == SelectionKind.clip && index == i;
  bool isOverlay(int i) => kind == SelectionKind.overlay && index == i;
  bool isTransition(int i) => kind == SelectionKind.transition && index == i;
  bool isPip(int i) => kind == SelectionKind.pip && index == i;
  bool isAudio(int i) => kind == SelectionKind.audio && index == i;
  bool get isMusic => kind == SelectionKind.music;
  bool get isNone => kind == SelectionKind.none;

  @override
  bool operator ==(Object other) =>
      other is Selection && other.kind == kind && other.index == index;
  @override
  int get hashCode => Object.hash(kind, index);
}

/// Timeline stile CapCut: testina fissa al centro, si scorre la timeline.
/// - pizzica con due dita per lo zoom
/// - tieni premuta una clip e trascinala per spostarla
/// - trascina le maniglie bianche per tagliare inizio/fine
/// - tocca il quadratino tra due clip per la transizione
class Timeline extends StatefulWidget {
  const Timeline({
    super.key,
    required this.project,
    required this.position,
    required this.playing,
    required this.selection,
    required this.thumbnails,
    required this.onScrub,
    required this.onSelect,
    required this.onChanged,
    required this.onCommit,
    required this.onAddClip,
  });

  final Project project;
  final Duration position;
  final bool playing;
  final Selection selection;
  final Map<String, List<String>> thumbnails;
  final ValueChanged<Duration> onScrub;
  final ValueChanged<Selection> onSelect;

  /// Modifica "dal vivo" (durante un trascinamento).
  final VoidCallback onChanged;

  /// Fine di una modifica: da registrare per annulla/ripeti.
  final VoidCallback onCommit;
  final VoidCallback onAddClip;

  @override
  State<Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<Timeline> {
  final _scroll = ScrollController();
  double _pps = 60; // pixel per secondo
  bool _programmatic = false;
  bool _pinching = false;

  // Pizzico.
  final _pointers = <int, Offset>{};
  double? _pinchStartDist;
  double _pinchStartPps = 60;

  // Riordino.
  int? _dragClip;
  double _dragDx = 0;

  static const _rulerH = 18.0;
  static const _clipH = 60.0;
  static const _laneH = 26.0;
  static const _gap = 6.0;

  Project get _p => widget.project;
  double _px(Duration d) => d.inMicroseconds / 1e6 * _pps;
  Duration _dur(double px) => Duration(microseconds: (px / _pps * 1e6).round());

  @override
  void didUpdateWidget(covariant Timeline old) {
    super.didUpdateWidget(old);
    _syncScroll();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncScroll());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Porta la timeline alla posizione corrente (senza far partire uno scrub).
  void _syncScroll() {
    if (!_scroll.hasClients) return;
    final target = _px(widget.position)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    if ((target - _scroll.offset).abs() < 0.5) return;
    _programmatic = true;
    _scroll.jumpTo(target);
    _programmatic = false;
  }

  bool _onScroll(ScrollNotification n) {
    if (_programmatic || _pinching) return false;
    if (n is ScrollUpdateNotification) {
      widget.onScrub(_dur(_scroll.offset));
    }
    return false;
  }

  // ── Pizzico con due dita (Listener: non entra in conflitto con lo scroll) ──
  void _pointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) {
      final v = _pointers.values.toList();
      _pinchStartDist = (v[0] - v[1]).distance;
      _pinchStartPps = _pps;
      setState(() => _pinching = true);
    }
  }

  void _pointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2 && _pinchStartDist != null && _pinchStartDist! > 10) {
      final v = _pointers.values.toList();
      final ratio = (v[0] - v[1]).distance / _pinchStartDist!;
      setState(() => _pps = (_pinchStartPps * ratio).clamp(12.0, 400.0));
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncScroll());
    }
  }

  void _pointerUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2 && _pinching) {
      _pinchStartDist = null;
      setState(() => _pinching = false);
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncScroll());
    }
  }

  /// Assegna corsie agli overlay che si sovrappongono nel tempo.
  List<int> _lanes(List<int> indices) {
    final laneEnds = <Duration>[];
    final lanes = List<int>.filled(_p.overlays.length, 0);
    final sorted = [...indices]
      ..sort((a, b) => _p.overlays[a].start.compareTo(_p.overlays[b].start));
    for (final i in sorted) {
      final o = _p.overlays[i];
      var lane = laneEnds.indexWhere((e) => e <= o.start);
      if (lane < 0) {
        lane = laneEnds.length;
        laneEnds.add(o.end);
      } else {
        laneEnds[lane] = o.end;
      }
      lanes[i] = lane;
    }
    return lanes;
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final half = MediaQuery.sizeOf(context).width / 2;
    final total = _p.totalDuration;

    final textIdx = <int>[], subIdx = <int>[];
    for (var i = 0; i < _p.overlays.length; i++) {
      (_p.overlays[i].kind == OverlayKind.subtitle ? subIdx : textIdx).add(i);
    }
    final lanes = _lanes(textIdx);
    final textLanes = textIdx.isEmpty ? 0 : textIdx.map((i) => lanes[i]).reduce(math.max) + 1;
    final subLanes = subIdx.isEmpty ? 0 : 1;

    var y = _rulerH;
    final clipTop = y;
    y += _clipH + _gap;
    final textTop = y;
    y += math.max(1, textLanes) * (_laneH + 2) + _gap;
    final subTop = y;
    if (subLanes > 0) y += _laneH + _gap;
    final pipLanes = _timeLanes([for (final l in _p.pips) (l.start, l.end)]);
    final pipTop = y;
    if (_p.pips.isNotEmpty) y += (pipLanes.reduce(math.max) + 1) * (_laneH + 2) + _gap;
    final audioLanes = _timeLanes([for (final a in _p.audios) (a.start, a.end)]);
    final audioTop = y;
    if (_p.audios.isNotEmpty) y += (audioLanes.reduce(math.max) + 1) * (_laneH + 2) + _gap;
    final musicTop = y;
    y += _laneH + 4;
    final height = y;

    final children = <Widget>[];

    // Righello.
    final step = _pps >= 120 ? 1 : (_pps >= 40 ? 2 : 5);
    for (var s = 0; s <= total.inSeconds; s += step) {
      children.add(Positioned(
        left: half + s * _pps + 3,
        top: 0,
        child: Text(_label(s), style: const TextStyle(fontSize: 10, color: Colors.white38)),
      ));
      children.add(Positioned(
        left: half + s * _pps,
        top: 2,
        child: Container(width: 1, height: 10, color: Colors.white24),
      ));
    }

    // Clip.
    for (var i = 0; i < _p.clips.length; i++) {
      children.add(_clipBlock(i, half, clipTop, accent));
    }
    // Pulsanti transizione tra le clip.
    for (var i = 0; i < _p.clips.length - 1; i++) {
      final x = half + _px(_p.startOf(i + 1));
      final t = _p.clips[i].transition;
      final sel = widget.selection.isTransition(i);
      children.add(Positioned(
        left: x - 13,
        top: clipTop + _clipH / 2 - 13,
        child: GestureDetector(
          onTap: () => widget.onSelect(Selection(SelectionKind.transition, i)),
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: sel ? accent : Colors.white,
              borderRadius: BorderRadius.circular(6),
              boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black54)],
            ),
            child: Icon(
              t == TransitionType.none ? Icons.add_rounded : t.icon,
              size: 16,
              color: Colors.black,
            ),
          ),
        ),
      ));
    }
    // Aggiungi clip.
    children.add(Positioned(
      left: half + _px(total) + 10,
      top: clipTop + 10,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: widget.onAddClip,
          child: const SizedBox(
            width: 40,
            height: 40,
            child: Icon(Icons.add_rounded, color: Colors.black),
          ),
        ),
      ),
    ));

    // Testi / sticker.
    for (final i in textIdx) {
      final o = _p.overlays[i];
      children.add(_overlayBlock(
        i,
        half,
        textTop + lanes[i] * (_laneH + 2),
        o.kind == OverlayKind.sticker ? const Color(0xFFFF8FB1) : const Color(0xFFB98CFF),
        o.kind == OverlayKind.sticker ? o.text : 'T  ${o.text}',
      ));
    }
    if (textIdx.isEmpty) {
      children.add(Positioned(
        left: half + 4,
        top: textTop + 5,
        child: const Text('Testi e sticker', style: TextStyle(fontSize: 11, color: Colors.white24)),
      ));
    }
    // Sottotitoli.
    for (final i in subIdx) {
      children.add(_overlayBlock(i, half, subTop, const Color(0xFFFFE14D), _p.overlays[i].text));
    }
    // Sovrapposizioni (PiP).
    for (var k = 0; k < _p.pips.length; k++) {
      final l = _p.pips[k];
      children.add(_timeBlock(
        half: half,
        top: pipTop + pipLanes[k] * (_laneH + 2),
        start: l.start,
        end: l.end,
        color: const Color(0xFF4FA3FF),
        label: '${l.isImage ? '🖼' : '▣'}  ${p.basename(l.path)}',
        selected: widget.selection.isPip(k),
        onTap: () => widget.onSelect(Selection(SelectionKind.pip, k)),
        move: (d) {
          var s = l.start + d;
          if (s < Duration.zero) s = Duration.zero;
          if (s > _p.totalDuration - const Duration(milliseconds: 300)) {
            s = _p.totalDuration - const Duration(milliseconds: 300);
          }
          l.start = s;
        },
        resize: (d, atStart) {
          const minLen = Duration(milliseconds: 300);
          if (atStart) {
            // Accorcia/allunga dall'inizio tenendo ferma la fine.
            var ts = l.trimStart + d;
            if (ts < Duration.zero) ts = Duration.zero;
            if (ts > l.trimEnd - minLen) ts = l.trimEnd - minLen;
            l.start += ts - l.trimStart;
            l.trimStart = ts;
          } else {
            var te = l.trimEnd + d;
            final max = l.isImage ? const Duration(minutes: 10) : l.sourceDuration;
            if (te > max) te = max;
            if (te < l.trimStart + minLen) te = l.trimStart + minLen;
            l.trimEnd = te;
          }
        },
      ));
    }
    // Voci fuori campo ed effetti sonori.
    for (var k = 0; k < _p.audios.length; k++) {
      final a = _p.audios[k];
      children.add(_timeBlock(
        half: half,
        top: audioTop + audioLanes[k] * (_laneH + 2),
        start: a.start,
        end: a.end,
        color: const Color(0xFFFF9F43),
        label: a.isVoice ? '🎙  Voce ${k + 1}' : '🔊  ${p.basename(a.path)}',
        selected: widget.selection.isAudio(k),
        onTap: () => widget.onSelect(Selection(SelectionKind.audio, k)),
        move: (d) {
          var s = a.start + d;
          if (s < Duration.zero) s = Duration.zero;
          a.start = s;
        },
      ));
    }
    // Musica.
    if (_p.music != null) {
      children.add(_block(
        left: half,
        top: musicTop,
        width: _px(total),
        height: _laneH,
        color: const Color(0xFF5BD39B),
        selected: widget.selection.isMusic,
        label: '♪  ${p.basename(_p.music!.path)}',
        onTap: () => widget.onSelect(const Selection(SelectionKind.music)),
      ));
    } else {
      children.add(Positioned(
        left: half + 4,
        top: musicTop + 5,
        child: const Text('Musica', style: TextStyle(fontSize: 11, color: Colors.white24)),
      ));
    }

    return Listener(
      onPointerDown: _pointerDown,
      onPointerMove: _pointerMove,
      onPointerUp: _pointerUp,
      onPointerCancel: _pointerUp,
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                physics: _pinching
                    ? const NeverScrollableScrollPhysics()
                    : const ClampingScrollPhysics(),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => widget.onSelect(const Selection.none()),
                  child: SizedBox(
                    width: half * 2 + _px(total) + 60,
                    height: height,
                    child: Stack(clipBehavior: Clip.none, children: children),
                  ),
                ),
              ),
            ),
            // Testina fissa al centro.
            Positioned(
              left: half - 1,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  width: 2,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    boxShadow: [BoxShadow(blurRadius: 3, color: Colors.black)],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Corsie per elementi (inizio, fine) che si sovrappongono nel tempo.
  List<int> _timeLanes(List<(Duration, Duration)> items) {
    final lanes = List<int>.filled(items.length, 0);
    final order = List<int>.generate(items.length, (i) => i)
      ..sort((a, b) => items[a].$1.compareTo(items[b].$1));
    final ends = <Duration>[];
    for (final i in order) {
      var lane = ends.indexWhere((e) => e <= items[i].$1);
      if (lane < 0) {
        lane = ends.length;
        ends.add(items[i].$2);
      } else {
        ends[lane] = items[i].$2;
      }
      lanes[i] = lane;
    }
    return lanes;
  }

  /// Blocco generico spostabile nel tempo (e ridimensionabile se [resize]).
  Widget _timeBlock({
    required double half,
    required double top,
    required Duration start,
    required Duration end,
    required Color color,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required void Function(Duration delta) move,
    void Function(Duration delta, bool atStart)? resize,
  }) {
    final body = GestureDetector(
      onTap: onTap,
      onHorizontalDragUpdate: selected
          ? (d) {
              move(_dur(d.delta.dx));
              widget.onChanged();
            }
          : null,
      onHorizontalDragEnd: selected ? (_) => widget.onCommit() : null,
      child: Container(
        width: math.max(10, _px(end - start)),
        height: _laneH,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: selected ? Colors.white : Colors.transparent, width: 2),
        ),
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.black)),
      ),
    );
    Widget handle(bool atStart) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) {
            resize!(_dur(d.delta.dx), atStart);
            widget.onChanged();
          },
          onHorizontalDragEnd: (_) => widget.onCommit(),
          child: Container(
            width: 12,
            height: _laneH,
            color: Colors.white,
            child: const Icon(Icons.drag_indicator_rounded, size: 10, color: Colors.black),
          ),
        );
    final handles = selected && resize != null;
    return Positioned(
      left: half + _px(start) - (handles ? 12 : 0),
      top: top,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (handles) handle(true),
        body,
        if (handles) handle(false),
      ]),
    );
  }

  String _label(int s) => s < 60 ? '${s}s' : '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  // ── Blocco clip con miniature, maniglie e riordino ──────────────────────
  Widget _clipBlock(int i, double half, double top, Color accent) {
    final c = _p.clips[i];
    final last = i == _p.clips.length - 1;
    final width = _px(c.outputDuration - (last ? Duration.zero : _p.transitionAfter(i)));
    final left = half + _px(_p.startOf(i));
    final selected = widget.selection.isClip(i);
    final dragging = _dragClip == i;
    final thumbs = widget.thumbnails[c.path] ?? const <String>[];

    const tileW = 40.0;
    final tiles = <Widget>[];
    if (thumbs.isNotEmpty) {
      final n = (width / tileW).ceil();
      for (var j = 0; j < n; j++) {
        final src = c.sourceAt(_dur(j * tileW)).inMilliseconds / 1000;
        final k = src.floor().clamp(0, thumbs.length - 1);
        tiles.add(SizedBox(
          width: tileW,
          height: _clipH,
          child: Image.file(File(thumbs[k]),
              fit: BoxFit.cover, cacheHeight: 96, gaplessPlayback: true),
        ));
      }
    }

    final badges = [
      if (c.speed != 1.0) '${c.speed}x',
      if (c.effect != ClipEffect.none) c.effect.label,
      if (c.filter != VideoFilter.none) c.filter.label,
    ].join(' · ');

    final block = GestureDetector(
      onTap: () => widget.onSelect(Selection(SelectionKind.clip, i)),
      onLongPressStart: (_) {
        widget.onSelect(Selection(SelectionKind.clip, i));
        setState(() {
          _dragClip = i;
          _dragDx = 0;
        });
      },
      onLongPressMoveUpdate: (d) => setState(() => _dragDx = d.offsetFromOrigin.dx),
      onLongPressEnd: (_) => _finishReorder(i),
      child: Opacity(
        opacity: dragging ? 0.7 : 1,
        child: Container(
          width: math.max(6, width - 2),
          height: _clipH,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: selected ? Colors.white : Colors.transparent, width: 2),
          ),
          child: Stack(fit: StackFit.expand, children: [
            OverflowBox(
              alignment: Alignment.centerLeft,
              maxWidth: double.infinity,
              child: Row(mainAxisSize: MainAxisSize.min, children: tiles),
            ),
            if (badges.isNotEmpty)
              Positioned(
                left: 4,
                bottom: 3,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  color: Colors.black54,
                  child: Text(badges, style: const TextStyle(fontSize: 9)),
                ),
              ),
            if (!c.hasAudio)
              const Positioned(
                right: 4,
                top: 3,
                child: Icon(Icons.volume_off_rounded, size: 12),
              ),
          ]),
        ),
      ),
    );

    return Positioned(
      left: left - (selected ? 16 : 0) + (dragging ? _dragDx : 0),
      top: top + (dragging ? -6 : 0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) _handle(isStart: true, onDrag: (dx) => _trimClip(i, dx, true)),
          block,
          if (selected) _handle(isStart: false, onDrag: (dx) => _trimClip(i, dx, false)),
        ],
      ),
    );
  }

  void _finishReorder(int from) {
    final c = _p.clips[from];
    final center = _px(_p.startOf(from)) + _px(c.outputDuration) / 2 + _dragDx;
    var to = 0;
    for (var j = 0; j < _p.clips.length; j++) {
      final mid = _px(_p.startOf(j)) + _px(_p.clips[j].outputDuration) / 2;
      if (center > mid) to = j;
    }
    if (center < _px(_p.startOf(0)) + _px(_p.clips[0].outputDuration) / 2) to = 0;
    setState(() {
      _dragClip = null;
      _dragDx = 0;
    });
    if (to != from) {
      final moved = _p.clips.removeAt(from);
      _p.clips.insert(to, moved);
      widget.onSelect(Selection(SelectionKind.clip, to));
      widget.onChanged();
      widget.onCommit();
    }
  }

  void _trimClip(int i, double dx, bool start) {
    final c = _p.clips[i];
    final delta = Duration(microseconds: (dx / _pps * c.speed * 1e6).round());
    const minLen = Duration(milliseconds: 300);
    if (start) {
      var v = c.trimStart + delta;
      if (v < Duration.zero) v = Duration.zero;
      if (v > c.trimEnd - minLen) v = c.trimEnd - minLen;
      c.trimStart = v;
    } else {
      var v = c.trimEnd + delta;
      if (v > c.sourceDuration) v = c.sourceDuration;
      if (v < c.trimStart + minLen) v = c.trimStart + minLen;
      c.trimEnd = v;
    }
    widget.onChanged();
  }

  Widget _handle({required bool isStart, required ValueChanged<double> onDrag}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
      onHorizontalDragEnd: (_) => widget.onCommit(),
      child: Container(
        width: 16,
        height: _clipH,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.horizontal(
            left: isStart ? const Radius.circular(6) : Radius.zero,
            right: isStart ? Radius.zero : const Radius.circular(6),
          ),
        ),
        child: Icon(isStart ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
            size: 16, color: Colors.black),
      ),
    );
  }

  // ── Overlay: tocca per selezionare, trascina per spostare nel tempo ─────
  Widget _overlayBlock(int i, double half, double top, Color color, String label) {
    final o = _p.overlays[i];
    final selected = widget.selection.isOverlay(i);
    final total = _p.totalDuration;

    void move(double dx) {
      final d = _dur(dx);
      final len = o.end - o.start;
      var s = o.start + d;
      if (s < Duration.zero) s = Duration.zero;
      if (s + len > total) s = total - len;
      o.start = s;
      o.end = s + len;
      widget.onChanged();
    }

    void resize(double dx, bool start) {
      final d = _dur(dx);
      const minLen = Duration(milliseconds: 300);
      if (start) {
        var s = o.start + d;
        if (s < Duration.zero) s = Duration.zero;
        if (s > o.end - minLen) s = o.end - minLen;
        o.start = s;
      } else {
        var e = o.end + d;
        if (e > total) e = total;
        if (e < o.start + minLen) e = o.start + minLen;
        o.end = e;
      }
      widget.onChanged();
    }

    final body = GestureDetector(
      onTap: () => widget.onSelect(Selection(SelectionKind.overlay, i)),
      onHorizontalDragUpdate: selected ? (d) => move(d.delta.dx) : null,
      onHorizontalDragEnd: selected ? (_) => widget.onCommit() : null,
      child: Container(
        width: math.max(10, _px(o.end - o.start)),
        height: _laneH,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: selected ? Colors.white : Colors.transparent, width: 2),
        ),
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.black)),
      ),
    );

    Widget handle(bool start) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => resize(d.delta.dx, start),
          onHorizontalDragEnd: (_) => widget.onCommit(),
          child: Container(
            width: 12,
            height: _laneH,
            color: Colors.white,
            child: const Icon(Icons.drag_indicator_rounded, size: 10, color: Colors.black),
          ),
        );

    return Positioned(
      left: half + _px(o.start) - (selected ? 12 : 0),
      top: top,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (selected) handle(true),
        body,
        if (selected) handle(false),
      ]),
    );
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
  }) {
    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: math.max(10, width),
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: selected ? Colors.white : Colors.transparent, width: 2),
          ),
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.black)),
        ),
      ),
    );
  }
}
