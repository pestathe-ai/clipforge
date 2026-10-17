import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../models/project.dart';
import '../render/overlay_painter.dart';
import '../services/ffmpeg_service.dart';
import '../services/subtitle_service.dart';
import '../state/history.dart';
import '../widgets/edit_sheets.dart';
import '../widgets/subtitle_sheet.dart';
import '../widgets/timeline.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.project, this.pickOnStart = true});
  final Project project;
  final bool pickOnStart;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> with SingleTickerProviderStateMixin {
  final _ffmpeg = FFmpegService();
  late final _subs = SubtitleService(_ffmpeg);
  late Project _p = widget.project;
  late final _history = History(_p);

  VideoPlayerController? _video;
  VideoPlayerController? _musicPlayer;
  String? _musicPath;
  int _clipIndex = -1;
  String? _loadedPath;
  bool _switching = false;
  bool _playing = false;
  String? _busy;
  Duration _position = Duration.zero;
  Selection _selection = const Selection.none();
  final _thumbs = <String, List<String>>{};

  // Riproduzione fluida: la posizione viene stimata a ogni frame.
  late final Ticker _ticker = createTicker(_onFrame);
  final _clock = Stopwatch();
  Duration _anchor = Duration.zero;
  Duration _anchorWall = Duration.zero;

  // Gesti sugli overlay nell'anteprima.
  double _gCx = 0, _gCy = 0, _gFont = 0, _gRot = 0;
  Offset _gFocal = Offset.zero;
  bool _gActive = false;

  @override
  void initState() {
    super.initState();
    _clock.start();
    for (final c in _p.clips) {
      _loadThumbs(c.path);
    }
    if (_p.music != null) _loadMusic(_p.music!.path);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_p.clips.isEmpty && widget.pickOnStart) {
        _addClips();
      } else {
        _refresh();
      }
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _video?.dispose();
    _musicPlayer?.dispose();
    super.dispose();
  }

  // ───────────────────────── Stato e cronologia ─────────────────────────

  void _changed() => setState(() {});

  void _commit() {
    _p.clampOverlays();
    _history.commit(_p);
    _refresh();
  }

  Future<void> _undo() async {
    if (!_history.canUndo) return;
    _replaceProject(_history.undo());
  }

  Future<void> _redo() async {
    if (!_history.canRedo) return;
    _replaceProject(_history.redo());
  }

  void _replaceProject(Project p) {
    setState(() {
      _p = p;
      _selection = const Selection.none();
    });
    if (_p.music?.path != _musicPath) {
      _musicPlayer?.dispose();
      _musicPlayer = null;
      _musicPath = null;
      if (_p.music != null) _loadMusic(_p.music!.path);
    }
    _refresh();
  }

  // ───────────────────────── Riproduzione ─────────────────────────

  /// Carica la clip visibile all'istante [t] e si posiziona.
  Future<void> _seek(Duration t, {bool keepPlaying = false}) async {
    if (_p.clips.isEmpty) {
      final old = _video;
      setState(() {
        _video = null;
        _clipIndex = -1;
        _position = Duration.zero;
      });
      await old?.dispose();
      return;
    }
    final total = _p.totalDuration;
    if (t > total) t = total;
    if (t < Duration.zero) t = Duration.zero;

    final index = _p.clipIndexAt(t);
    final clip = _p.clips[index];
    var local = t - _p.startOf(index);
    if (local < Duration.zero) local = Duration.zero;
    final sourcePos = clip.sourceAt(local);

    if (_video == null || index != _clipIndex || _loadedPath != clip.path) {
      _switching = true;
      try {
        final old = _video;
        final c = VideoPlayerController.file(File(clip.path));
        await c.initialize();
        _video = c;
        _clipIndex = index;
        _loadedPath = clip.path;
        if (mounted) setState(() {});
        await old?.dispose();
      } finally {
        _switching = false;
      }
    }
    final c = _video!;
    await c.setPlaybackSpeed(clip.speed);
    await c.setVolume(clip.volume.clamp(0.0, 1.0));
    await c.seekTo(sourcePos);
    await _seekMusic(t);
    _anchor = t;
    _anchorWall = _clock.elapsed;
    if (keepPlaying || _playing) {
      await c.play();
      await _musicPlayer?.play();
    }
    if (mounted) setState(() => _position = t);
  }

  Future<void> _seekMusic(Duration t) async {
    final m = _p.music, mp = _musicPlayer;
    if (m == null || mp == null || m.duration <= Duration.zero) return;
    final pos = (m.offset + t).inMicroseconds % m.duration.inMicroseconds;
    await mp.seekTo(Duration(microseconds: pos));
    await mp.setVolume(m.volume.clamp(0.0, 1.0));
  }

  void _onFrame(Duration _) {
    if (!_playing || _switching || _clipIndex < 0) return;
    final est = _anchor + (_clock.elapsed - _anchorWall);
    final i = _clipIndex;
    final clip = _p.clips[i];
    final boundary = _p.startOf(i) + clip.outputDuration - _p.transitionAfter(i) ~/ 2;
    if (est >= _p.totalDuration) {
      _pause();
      _seek(Duration.zero);
      return;
    }
    if (est >= boundary && i + 1 < _p.clips.length) {
      _seek(est, keepPlaying: true);
      return;
    }
    // Ri-aggancia alla posizione reale del player se ci si discosta troppo.
    final v = _video;
    if (v != null && v.value.isPlaying) {
      final real = _p.startOf(i) +
          Duration(
              microseconds: ((v.value.position - clip.trimStart).inMicroseconds / clip.speed).round());
      if ((real - est).abs() > const Duration(milliseconds: 250)) {
        _anchor = real;
        _anchorWall = _clock.elapsed;
      }
    }
    setState(() => _position = est);
  }

  Future<void> _play() async {
    if (_p.clips.isEmpty) return;
    setState(() => _playing = true);
    final start = _position >= _p.totalDuration - const Duration(milliseconds: 100)
        ? Duration.zero
        : _position;
    await _seek(start, keepPlaying: true);
    if (!_ticker.isActive) _ticker.start();
  }

  Future<void> _pause() async {
    _ticker.stop();
    setState(() => _playing = false);
    await _video?.pause();
    await _musicPlayer?.pause();
  }

  Future<void> _refresh() async {
    if (_playing) await _pause();
    _clipIndex = -1;
    await _seek(_position);
  }

  // ───────────────────────── Importazione ─────────────────────────

  /// Copia i file scelti nella cartella dell'app, così il progetto
  /// resta valido anche se la cache del selettore viene svuotata.
  Future<String> _keep(String path) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'media'));
    await dir.create(recursive: true);
    final dest = p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}_${p.basename(path)}');
    await File(path).copy(dest);
    return dest;
  }

  Future<void> _loadThumbs(String path) async {
    final t = await _ffmpeg.thumbnails(path);
    if (mounted && t.isNotEmpty) setState(() => _thumbs[path] = t);
  }

  Future<void> _addClips() async {
    await _pause();
    final res = await FilePicker.platform.pickFiles(type: FileType.video, allowMultiple: true);
    if (res == null) return;
    setState(() => _busy = 'Importo i video…');
    final insertAt = _p.clips.isEmpty ? 0 : _p.clipIndexAt(_position) + 1;
    var added = 0;
    try {
      for (final f in res.files) {
        if (f.path == null) continue;
        final path = await _keep(f.path!);
        final info = await _ffmpeg.probe(path);
        if (!info.hasVideo || info.duration <= Duration.zero) {
          _toast('${f.name}: nessuna traccia video');
          continue;
        }
        _p.clips.insert(insertAt + added, VideoClip(
          path: path,
          sourceDuration: info.duration,
          hasAudio: info.hasAudio,
        ));
        added++;
        _loadThumbs(path);
      }
    } catch (e) {
      _toast('Errore durante l\'importazione: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    if (added > 0) _commit();
  }

  Future<void> _loadMusic(String path) async {
    final m = VideoPlayerController.file(File(path));
    await m.initialize();
    await m.setLooping(true);
    _musicPlayer = m;
    _musicPath = path;
  }

  Future<void> _addMusic() async {
    await _pause();
    final res = await FilePicker.platform.pickFiles(type: FileType.audio);
    final picked = res?.files.single.path;
    if (picked == null) return;
    try {
      final path = await _keep(picked);
      final info = await _ffmpeg.probe(path);
      if (!info.hasAudio) {
        _toast('Il file non contiene audio');
        return;
      }
      await _musicPlayer?.dispose();
      await _loadMusic(path);
      _p.music = MusicTrack(path: path, duration: info.duration);
      _commit();
    } catch (e) {
      _toast('Impossibile aprire il brano: $e');
    }
  }

  // ───────────────────────── Modifiche alle clip ─────────────────────────

  int get _targetClip =>
      _selection.kind == SelectionKind.clip ? _selection.index : _p.clipIndexAt(_position);

  Future<void> _editClip(Future<bool?> Function(VideoClip c) sheet) async {
    if (_p.clips.isEmpty) return;
    await _pause();
    final i = _targetClip;
    if (!mounted) return;
    await sheet(_p.clips[i]);
    _commit();
  }

  void _splitClip() {
    final i = _targetClip;
    final clip = _p.clips[i];
    final cut = clip.sourceAt(_position - _p.startOf(i));
    const minLen = Duration(milliseconds: 200);
    if (cut - clip.trimStart < minLen || clip.trimEnd - cut < minLen) {
      _toast('Sposta la testina dentro la clip per dividerla');
      return;
    }
    final second = clip.copy()..trimStart = cut;
    clip
      ..trimEnd = cut
      ..transition = TransitionType.none;
    _p.clips.insert(i + 1, second);
    _selection = Selection(SelectionKind.clip, i + 1);
    _commit();
  }

  void _duplicateClip() {
    final i = _targetClip;
    _p.clips.insert(i + 1, _p.clips[i].copy());
    _selection = Selection(SelectionKind.clip, i + 1);
    _commit();
  }

  void _deleteSelected() {
    switch (_selection.kind) {
      case SelectionKind.clip:
        _p.clips.removeAt(_selection.index);
      case SelectionKind.overlay:
        _p.overlays.removeAt(_selection.index);
      case SelectionKind.music:
        _p.music = null;
        _musicPlayer?.dispose();
        _musicPlayer = null;
        _musicPath = null;
      case SelectionKind.transition:
      case SelectionKind.none:
        break;
    }
    _selection = const Selection.none();
    _commit();
  }

  Future<void> _onSelect(Selection s) async {
    if (s.kind == SelectionKind.transition) {
      await _pause();
      if (!mounted) return;
      await showTransitionSheet(context, _p.clips[s.index], applyToAll: () {
        final src = _p.clips[s.index];
        for (final c in _p.clips) {
          c.transition = src.transition;
          c.transitionDuration = src.transitionDuration;
        }
        Navigator.pop(context, true);
      });
      // Anteprima del punto della transizione.
      _position = _p.startOf(s.index + 1) - _p.transitionAfter(s.index);
      _commit();
      return;
    }
    setState(() => _selection = s);
  }

  // ───────────────────────── Testi, sticker, sottotitoli ─────────────────────────

  Future<void> _addOrEditText([int? index]) async {
    if (_p.clips.isEmpty) return _toast('Aggiungi prima un video');
    await _pause();
    if (!mounted) return;
    final res = await showTextSheet(
      context,
      total: _p.totalDuration,
      at: _position,
      existing: index == null ? null : _p.overlays[index],
    );
    if (res == null) return;
    if (index == null) {
      _p.overlays.add(res);
      _selection = Selection(SelectionKind.overlay, _p.overlays.length - 1);
    } else {
      _p.overlays[index] = res;
    }
    _commit();
  }

  Future<void> _addSticker() async {
    if (_p.clips.isEmpty) return _toast('Aggiungi prima un video');
    await _pause();
    if (!mounted) return;
    final emoji = await showStickerSheet(context);
    if (emoji == null) return;
    final total = _p.totalDuration;
    final end = _position + const Duration(seconds: 3);
    _p.overlays.add(VideoOverlay(
      kind: OverlayKind.sticker,
      text: emoji,
      start: _position >= total ? Duration.zero : _position,
      end: end > total ? total : end,
      fontSize: 200,
      outline: false,
      cx: 0.5,
      cy: 0.4,
      animIn: AnimIn.bounce,
      animOut: AnimOut.fade,
    ));
    _selection = Selection(SelectionKind.overlay, _p.overlays.length - 1);
    _commit();
  }

  Future<void> _autoSubtitles() async {
    if (_p.clips.isEmpty) return _toast('Aggiungi prima un video');
    await _pause();
    if (!mounted) return;
    final subs = await showSubtitleSheet(context, _p, _subs);
    if (subs == null) return;
    _p.overlays.removeWhere((o) => o.kind == OverlayKind.subtitle);
    _p.overlays.addAll(subs);
    _commit();
    _toast('${subs.length} sottotitoli creati: toccali sulla timeline per correggerli');
  }

  void _duplicateOverlay() {
    final o = _p.overlays[_selection.index].copy()
      ..cy = (_p.overlays[_selection.index].cy + 0.06).clamp(0.05, 0.95);
    _p.overlays.add(o);
    _selection = Selection(SelectionKind.overlay, _p.overlays.length - 1);
    _commit();
  }

  /// Applica lo stile di un sottotitolo a tutti i sottotitoli.
  void _styleAllSubtitles(VideoOverlay src) {
    for (final o in _p.overlays) {
      if (o.kind != OverlayKind.subtitle || identical(o, src)) continue;
      o
        ..color = src.color
        ..box = src.box
        ..boxColor = src.boxColor
        ..outline = src.outline
        ..fontSize = src.fontSize
        ..cx = src.cx
        ..cy = src.cy
        ..animIn = src.animIn
        ..animOut = src.animOut;
    }
    _commit();
  }

  // ───────────────────────── Esportazione ─────────────────────────

  Future<void> _export() async {
    if (_p.clips.isEmpty) return _toast('Non c\'è niente da esportare');
    await _pause();
    if (!mounted) return;
    final progress = ValueNotifier<double>(0);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Esportazione'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, v, __) => Column(mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(value: v),
            const SizedBox(height: 12),
            Text('${(v * 100).round()}%'),
            const SizedBox(height: 4),
            const Text('Tieni l\'app aperta.', style: TextStyle(fontSize: 12, color: Colors.white54)),
          ]),
        ),
        actions: [TextButton(onPressed: _ffmpeg.cancel, child: const Text('Annulla'))],
      ),
    );

    try {
      final out = await _ffmpeg.export(_p, onProgress: (v) => progress.value = v);
      if (!mounted) return;
      Navigator.of(context).pop();
      var saved = false;
      try {
        if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
        await Gal.putVideo(out, album: 'ClipForge');
        saved = true;
      } catch (_) {}
      _toast(saved ? 'Video salvato nella galleria (album ClipForge)' : 'Video esportato in: $out');
    } on ExportException catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      if (e.log != null) debugPrint(e.log);
      _toast(e.message);
    } finally {
      progress.dispose();
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        titleSpacing: 0,
        title: Row(children: [
          IconButton(
            tooltip: 'Annulla',
            onPressed: _history.canUndo ? _undo : null,
            icon: const Icon(Icons.undo_rounded),
          ),
          IconButton(
            tooltip: 'Ripeti',
            onPressed: _history.canRedo ? _redo : null,
            icon: const Icon(Icons.redo_rounded),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () async {
              await _pause();
              if (!mounted) return;
              await showFormatSheet(context, _p);
              _commit();
            },
            child: Text(_p.aspect.label),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(onPressed: _export, child: const Text('Esporta')),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _preview()),
          _transport(),
          Timeline(
            project: _p,
            position: _position,
            playing: _playing,
            selection: _selection,
            thumbnails: _thumbs,
            onScrub: (t) {
              if (_playing) _pause();
              setState(() => _position = t);
              _seekDebounced(t);
            },
            onSelect: _onSelect,
            onChanged: _changed,
            onCommit: _commit,
            onAddClip: _addClips,
          ),
          const SizedBox(height: 6),
          _toolbar(),
        ],
      ),
    );
  }

  // Durante lo scrub carichiamo il fotogramma al massimo ogni 80 ms.
  DateTime _lastScrub = DateTime(0);
  bool _scrubPending = false;
  void _seekDebounced(Duration t) {
    final now = DateTime.now();
    if (now.difference(_lastScrub) > const Duration(milliseconds: 80)) {
      _lastScrub = now;
      _seek(t);
    } else if (!_scrubPending) {
      _scrubPending = true;
      Future.delayed(const Duration(milliseconds: 90), () {
        _scrubPending = false;
        _seek(_position);
      });
    }
  }

  // ── Anteprima ───────────────────────────────────────────────────

  Widget _preview() {
    if (_busy != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(_busy!),
        ]),
      );
    }
    final c = _video;
    if (_p.clips.isEmpty || c == null || !c.value.isInitialized) {
      return Center(
        child: FilledButton.tonalIcon(
          onPressed: _addClips,
          icon: const Icon(Icons.add_rounded),
          label: const Text('Aggiungi video'),
        ),
      );
    }

    final i = _clipIndex.clamp(0, _p.clips.length - 1);
    final clip = _p.clips[i];
    final localS = math.max(0.0, (_position - _p.startOf(i)).inMicroseconds / 1e6);
    final durS = math.max(0.01, clip.outputDuration.inMicroseconds / 1e6);

    Widget video = SizedBox(
      width: c.value.size.width,
      height: c.value.size.height,
      child: VideoPlayer(c),
    );

    final fg = FittedBox(fit: BoxFit.contain, child: video);
    final Widget bg = switch (_p.background) {
      CanvasBackground.black => const ColoredBox(color: Colors.black),
      CanvasBackground.white => const ColoredBox(color: Colors.white),
      CanvasBackground.blur => ClipRect(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: FittedBox(fit: BoxFit.cover, child: video),
          ),
        ),
    };

    Widget frame = Stack(fit: StackFit.expand, children: [bg, fg]);
    final m = clip.filter.previewMatrix;
    if (m != null) frame = ColorFiltered(colorFilter: ColorFilter.matrix(m), child: frame);
    frame = _applyEffect(clip.effect, frame, localS, durS);

    return Center(
      child: AspectRatio(
        aspectRatio: _p.aspect.ratio,
        child: LayoutBuilder(builder: (context, box) {
          final size = box.biggest;
          final selected = _selection.kind == SelectionKind.overlay ? _p.overlays[_selection.index] : null;
          return GestureDetector(
            onTapUp: (d) => _tapPreview(d.localPosition, size),
            onScaleStart: (d) => _overlayGestureStart(d.localFocalPoint, size),
            onScaleUpdate: (d) => _overlayGestureUpdate(d, size),
            onScaleEnd: (_) {
              if (_gActive) {
                _gActive = false;
                _commit();
              }
            },
            child: ClipRect(
              child: Stack(fit: StackFit.expand, children: [
                frame,
                CustomPaint(
                  painter: OverlaysPainter(
                    overlays: _p.overlays,
                    time: _position,
                    frameWidth: _p.aspect.width,
                    selected: selected,
                  ),
                ),
                if (!_playing)
                  const Positioned(
                    right: 8,
                    bottom: 8,
                    child: Icon(Icons.play_circle_fill_rounded, color: Colors.white54, size: 28),
                  ),
              ]),
            ),
          );
        }),
      ),
    );
  }

  /// Anteprima approssimata degli effetti (l'export usa FFmpeg).
  Widget _applyEffect(ClipEffect e, Widget child, double t, double d) {
    switch (e) {
      case ClipEffect.none:
        return child;
      case ClipEffect.zoomIn:
        return Transform.scale(scale: 1 + 0.18 * (t / d).clamp(0, 1), child: child);
      case ClipEffect.zoomOut:
        return Transform.scale(scale: 1.18 - 0.18 * (t / d).clamp(0, 1), child: child);
      case ClipEffect.shake:
        return Transform.scale(
          scale: 1 / 0.94,
          child: Transform.translate(
            offset: Offset(math.sin(t * 40) * 5, math.cos(t * 33) * 5),
            child: child,
          ),
        );
      case ClipEffect.mirror:
        return Transform.flip(flipX: true, child: child);
      case ClipEffect.blur:
        return ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6), child: child);
      case ClipEffect.vignette:
        return Stack(fit: StackFit.expand, children: [
          child,
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [Colors.transparent, Color(0xCC000000)],
                stops: [0.55, 1.0],
                radius: 0.9,
              ),
            ),
          ),
        ]);
      case ClipEffect.glitch:
        return Stack(fit: StackFit.expand, children: [
          child,
          Transform.translate(
            offset: Offset(math.sin(t * 23) * 4, 0),
            child: Opacity(
              opacity: 0.35,
              child: ColorFiltered(
                colorFilter: const ColorFilter.matrix([
                  1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, //
                ]),
                child: child,
              ),
            ),
          ),
        ]);
      case ClipEffect.vhs:
        return ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            1.0, 0.1, 0, 0, 10, //
            0.05, 0.9, 0.05, 0, 5,
            0, 0.1, 0.75, 0, 0,
            0, 0, 0, 1, 0,
          ]),
          child: child,
        );
      case ClipEffect.flash:
        final o = (1 - t / 0.35).clamp(0.0, 1.0);
        return Stack(fit: StackFit.expand, children: [
          child,
          if (o > 0) ColoredBox(color: Colors.white.withValues(alpha: o)),
        ]);
    }
  }

  /// Overlay sotto il dito (il più in alto), o null.
  int? _hitOverlay(Offset pos, Size size) {
    final scale = size.width / _p.aspect.width;
    final t = _position.inMicroseconds / 1e6;
    for (var i = _p.overlays.length - 1; i >= 0; i--) {
      final o = _p.overlays[i];
      if (!o.visibleAt(_position)) continue;
      final a = o.animAt(t);
      final l = OverlayLayout(o, scale: scale, frameWidth: _p.aspect.width);
      final r = Rect.fromCenter(
        center: Offset((o.cx + a.dx) * size.width, (o.cy + a.dy) * size.height),
        width: l.size.width + 24,
        height: l.size.height + 24,
      );
      if (r.contains(pos)) return i;
    }
    return null;
  }

  void _tapPreview(Offset pos, Size size) {
    final hit = _hitOverlay(pos, size);
    if (hit != null) {
      if (_selection.isOverlay(hit)) {
        final o = _p.overlays[hit];
        if (o.kind != OverlayKind.sticker) _addOrEditText(hit);
      } else {
        _pause();
        setState(() => _selection = Selection(SelectionKind.overlay, hit));
      }
      return;
    }
    _playing ? _pause() : _play();
  }

  void _overlayGestureStart(Offset focal, Size size) {
    var idx = _selection.kind == SelectionKind.overlay ? _selection.index : null;
    final hit = _hitOverlay(focal, size);
    if (hit != null) idx = hit;
    if (idx == null || !_p.overlays[idx].visibleAt(_position)) {
      _gActive = false;
      return;
    }
    if (_playing) _pause();
    final o = _p.overlays[idx];
    _selection = Selection(SelectionKind.overlay, idx);
    _gActive = true;
    _gCx = o.cx;
    _gCy = o.cy;
    _gFont = o.fontSize;
    _gRot = o.rotation;
    _gFocal = focal;
    setState(() {});
  }

  void _overlayGestureUpdate(ScaleUpdateDetails d, Size size) {
    if (!_gActive) return;
    final o = _p.overlays[_selection.index];
    final delta = d.localFocalPoint - _gFocal;
    setState(() {
      o.cx = (_gCx + delta.dx / size.width).clamp(0.0, 1.0);
      o.cy = (_gCy + delta.dy / size.height).clamp(0.0, 1.0);
      if (d.pointerCount > 1) {
        o.fontSize = (_gFont * d.scale).clamp(20.0, 600.0);
        o.rotation = _gRot + d.rotation;
      }
    });
  }

  // ── Barra di riproduzione ───────────────────────────────────────

  Widget _transport() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        Text('${fmt(_position)} / ${fmt(_p.totalDuration)}',
            style: const TextStyle(fontSize: 12, fontFeatures: [ui.FontFeature.tabularFigures()])),
        const Spacer(),
        IconButton(
          iconSize: 34,
          onPressed: _p.clips.isEmpty ? null : (_playing ? _pause : _play),
          icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
        const Spacer(),
        const SizedBox(width: 90),
      ]),
    );
  }

  // ── Barra strumenti ───────────────────────────────────────────

  Widget _toolbar() {
    final items = <_Tool>[];
    switch (_selection.kind) {
      case SelectionKind.none:
      case SelectionKind.transition:
        items.addAll([
          _Tool(Icons.content_cut_rounded, 'Dividi', _p.clips.isEmpty ? null : _splitClip),
          _Tool(Icons.music_note_rounded, 'Audio', _addMusic),
          _Tool(Icons.title_rounded, 'Testo', () => _addOrEditText()),
          _Tool(Icons.emoji_emotions_rounded, 'Sticker', _addSticker),
          _Tool(Icons.subtitles_rounded, 'Sottotitoli', _autoSubtitles),
          _Tool(Icons.auto_awesome_rounded, 'Effetti', () => _editClip((c) => showEffectSheet(context, c))),
          _Tool(Icons.filter_vintage_rounded, 'Filtri', () => _editClip((c) => showFilterSheet(context, c, applyToAll: _filterAll(c)))),
          _Tool(Icons.speed_rounded, 'Velocità', () => _editClip((c) => showSpeedSheet(context, c))),
          _Tool(Icons.aspect_ratio_rounded, 'Formato', () async {
            await _pause();
            if (!mounted) return;
            await showFormatSheet(context, _p);
            _commit();
          }),
        ]);
      case SelectionKind.clip:
        final clip = _p.clips[_selection.index];
        items.addAll([
          _Tool(Icons.content_cut_rounded, 'Dividi', _splitClip),
          _Tool(Icons.speed_rounded, 'Velocità', () => _editClip((c) => showSpeedSheet(context, c))),
          _Tool(Icons.auto_awesome_rounded, 'Effetti', () => _editClip((c) => showEffectSheet(context, c))),
          _Tool(Icons.filter_vintage_rounded, 'Filtri', () => _editClip((c) => showFilterSheet(context, c, applyToAll: _filterAll(c)))),
          if (clip.hasAudio)
            _Tool(Icons.volume_up_rounded, 'Volume', () => _editClip((c) => showVolumeSheet(context,
                title: 'Volume clip', value: c.volume, onChanged: (v) => c.volume = v))),
          _Tool(Icons.crop_rounded, 'Taglia', () => _editClip((c) => showTrimSheet(context, c))),
          _Tool(Icons.copy_rounded, 'Duplica', _duplicateClip),
          _Tool(Icons.delete_outline_rounded, 'Elimina', _deleteSelected),
        ]);
      case SelectionKind.overlay:
        final i = _selection.index;
        final o = _p.overlays[i];
        if (o.kind != OverlayKind.sticker) {
          items.add(_Tool(Icons.edit_rounded, 'Modifica', () => _addOrEditText(i)));
        }
        items.add(_Tool(Icons.animation_rounded, 'Animazione', () async {
          await _pause();
          if (!mounted) return;
          await showStickerAnimSheet(context, o);
          _commit();
        }));
        if (o.kind == OverlayKind.subtitle) {
          items.add(_Tool(Icons.format_paint_rounded, 'Stile a tutti', () => _styleAllSubtitles(o)));
          items.add(_Tool(Icons.layers_clear_rounded, 'Togli tutti', () {
            _p.overlays.removeWhere((x) => x.kind == OverlayKind.subtitle);
            _selection = const Selection.none();
            _commit();
          }));
        } else {
          items.add(_Tool(Icons.copy_rounded, 'Duplica', _duplicateOverlay));
        }
        items.add(_Tool(Icons.delete_outline_rounded, 'Elimina', _deleteSelected));
      case SelectionKind.music:
        final m = _p.music!;
        items.addAll([
          _Tool(Icons.volume_up_rounded, 'Volume', () async {
            await showVolumeSheet(context,
                title: 'Volume musica',
                value: m.volume,
                onChanged: (v) {
                  m.volume = v;
                  _musicPlayer?.setVolume(v.clamp(0.0, 1.0));
                },
                fadeOut: m.fadeOut,
                onFadeOut: (v) => m.fadeOut = v);
            _commit();
          }),
          _Tool(Icons.swap_horiz_rounded, 'Cambia', _addMusic),
          _Tool(Icons.delete_outline_rounded, 'Rimuovi', _deleteSelected),
        ]);
    }

    return SafeArea(
      top: false,
      child: Container(
        height: 70,
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Colors.white10)),
        ),
        child: Row(children: [
          if (!_selection.isNone && _selection.kind != SelectionKind.transition)
            IconButton(
              onPressed: () => setState(() => _selection = const Selection.none()),
              icon: const Icon(Icons.keyboard_arrow_left_rounded),
            ),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              children: [
                for (final t in items)
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: t.onTap,
                    child: Opacity(
                      opacity: t.onTap == null ? 0.35 : 1,
                      child: SizedBox(
                        width: 68,
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(t.icon, size: 24),
                          const SizedBox(height: 4),
                          Text(t.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 10.5)),
                        ]),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  VoidCallback _filterAll(VideoClip src) => () {
        for (final c in _p.clips) {
          c.filter = src.filter;
        }
        Navigator.pop(context, true);
      };
}

class _Tool {
  _Tool(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
}
