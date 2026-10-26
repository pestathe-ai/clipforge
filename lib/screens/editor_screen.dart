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
import '../models/templates.dart';
import '../render/mask_painter.dart';
import '../render/overlay_painter.dart';
import '../services/ffmpeg_service.dart';
import '../services/ai_service.dart';
import '../services/subtitle_service.dart';
import '../state/history.dart';
import '../state/layer_players.dart';
import '../widgets/edit_sheets.dart';
import '../widgets/ken_burns_view.dart';
import '../widgets/meme_sheet.dart';
import '../widgets/subtitle_sheet.dart';
import '../widgets/timeline.dart';
import '../widgets/voice_sheet.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.project, this.pickOnStart = true, this.memeOnStart = false});
  final Project project;
  final bool pickOnStart;

  /// Apre il pannello Meme dopo aver scelto il video.
  final bool memeOnStart;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> with SingleTickerProviderStateMixin {
  final _ffmpeg = FFmpegService();
  late final _subs = SubtitleService(_ffmpeg);
  late final _ai = AiService(_ffmpeg);
  double _gToScale = 1, _gToRot = 0;
  double _appliedSpeed = 1;
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
  final _layers = LayerPlayers();
  bool _recordingVoice = false;

  // Riproduzione fluida: la posizione viene stimata a ogni frame.
  late final Ticker _ticker = createTicker(_onFrame);
  final _clock = Stopwatch();
  Duration _anchor = Duration.zero;
  Duration _anchorWall = Duration.zero;

  // Gesti sugli overlay nell'anteprima.
  double _gCx = 0, _gCy = 0, _gFont = 0, _gRot = 0, _gScale = 0;
  bool _gEditEnd = false; // keyframe: si sta spostando il punto di arrivo
  Offset _gFocal = Offset.zero;
  bool _gActive = false;

  @override
  void initState() {
    super.initState();
    _clock.start();
    for (final c in _p.clips) {
      c.isImage ? _thumbs[c.path] = [c.path] : _loadThumbs(c.path);
    }
    _layers.addListener(() {
      if (mounted) setState(() {});
    });
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
    _layers.dispose();
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

    if (clip.isImage) {
      final old = _video;
      _video = null;
      _clipIndex = index;
      _loadedPath = clip.path;
      await old?.dispose();
      await _seekMusic(t);
      await _layers.sync(_layerEntries(), t, playing: keepPlaying || _playing);
      _anchor = t;
      _anchorWall = _clock.elapsed;
      if (keepPlaying || _playing) await _musicPlayer?.play();
      if (mounted) setState(() => _position = t);
      return;
    }

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
    _appliedSpeed = clip.speedAt(local);
    await c.setPlaybackSpeed(_appliedSpeed);
    await c.setVolume(_recordingVoice ? 0 : clip.volume.clamp(0.0, 1.0));
    await c.seekTo(sourcePos);
    await _seekMusic(t);
    await _layers.sync(_layerEntries(), t, playing: keepPlaying || _playing);
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
    await mp.setVolume(_recordingVoice ? 0 : m.volume.clamp(0.0, 1.0));
  }

  /// Player secondari: sovrapposizioni video, voci e suoni.
  List<LayerEntry> _layerEntries() => [
        for (final l in _p.pips)
          if (!l.isImage)
            LayerEntry(
              key: l,
              path: l.path,
              start: l.start,
              sourceStart: l.trimStart,
              duration: l.duration,
              volume: _recordingVoice ? 0 : l.volume,
            ),
        for (final a in _p.audios)
          LayerEntry(
            key: a,
            path: a.path,
            start: a.start,
            sourceStart: a.sourceStart,
            duration: a.duration,
            volume: _recordingVoice ? 0 : a.volume,
          ),
      ];

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
    final entries = _layerEntries();
    if (entries.isNotEmpty && _layers.visibilityChanged(entries, est)) {
      _layers.sync(entries, est, playing: true);
    }
    // Ri-aggancia alla posizione reale del player se ci si discosta troppo.
    final v = _video;
    if (v != null && v.value.isPlaying && !clip.isImage) {
      final real = _p.startOf(i) +
          clip.localAt(v.value.position);
      // Curva di velocità: aggiorna la velocità del player quando cambia tratto.
      final sp = clip.speedAt(est - _p.startOf(i));
      if ((sp - _appliedSpeed).abs() > 0.01) {
        _appliedSpeed = sp;
        v.setPlaybackSpeed(sp);
      }
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
    await _layers.pauseAll();
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
    final res = await FilePicker.platform.pickFiles(type: FileType.media, allowMultiple: true);
    if (res == null) return;
    setState(() => _busy = 'Importo…');
    final insertAt = _p.clips.isEmpty ? 0 : _p.clipIndexAt(_position) + 1;
    var added = 0;
    try {
      for (final f in res.files) {
        if (f.path == null) continue;
        final path = await _keep(f.path!);
        if (_isImage(path)) {
          _p.clips.insert(insertAt + added, VideoClip.image(path));
          _thumbs[path] = [path];
          added++;
          continue;
        }
        final info = await _ffmpeg.probe(path);
        if (!info.hasVideo || info.duration <= Duration.zero) {
          _toast('${f.name}: nessuna traccia video');
          continue;
        }
        _p.clips.insert(insertAt + added, VideoClip(
          path: path,
          sourceDuration: info.duration,
          hasAudio: info.hasAudio,
          width: info.width,
          height: info.height,
        ));
        added++;
        _loadThumbs(path);
      }
    } catch (e) {
      _toast('Errore durante l\'importazione: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    if (added > 0) {
      _commit();
      if (widget.memeOnStart && !_memeOpened) {
        _memeOpened = true;
        await _openMeme();
      }
    }
  }

  bool _memeOpened = false;

  Future<void> _openMeme() async {
    if (_p.clips.isEmpty) return _toast('Aggiungi prima un video');
    await _pause();
    if (!mounted) return;
    final ok = await showMemeSheet(context, _p);
    if (ok == true) {
      _selection = const Selection.none();
      _commit();
    }
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
      case SelectionKind.pip:
        _p.pips.removeAt(_selection.index);
      case SelectionKind.audio:
        _p.audios.removeAt(_selection.index);
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
    if (index != null && _p.overlays[index].isMeme) return _openMeme();
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

  // ───────────────────────── Novità v0.3 ─────────────────────────

  static const _imageExt = {'.jpg', '.jpeg', '.png', '.webp', '.heic', '.heif', '.bmp', '.gif'};
  bool _isImage(String path) => _imageExt.contains(p.extension(path).toLowerCase());

  Duration _clampToTotal(Duration t) {
    final total = _p.totalDuration;
    final max = total - const Duration(milliseconds: 300);
    if (t > max) return max < Duration.zero ? Duration.zero : max;
    return t;
  }

  /// Sovrapposizione: video o foto sopra il video principale.
  Future<void> _addPip() async {
    if (_p.clips.isEmpty) return _toast('Aggiungi prima un video');
    await _pause();
    final res = await FilePicker.platform.pickFiles(type: FileType.media);
    final picked = res?.files.single.path;
    if (picked == null) return;
    setState(() => _busy = 'Preparo la sovrapposizione…');
    try {
      final path = await _keep(picked);
      final info = await _ffmpeg.probe(path);
      final image = _isImage(path);
      if (info.width <= 0 || info.height <= 0) {
        _toast('Non riesco a leggere questo file');
        return;
      }
      final start = _clampToTotal(_position);
      final room = _p.totalDuration - start;
      final dur = image ? (room < const Duration(seconds: 3) ? room : const Duration(seconds: 3)) : info.duration;
      _p.pips.add(PipLayer(
        path: path,
        isImage: image,
        sourceDuration: image ? const Duration(minutes: 10) : info.duration,
        width: info.width,
        height: info.height,
        hasAudio: !image && info.hasAudio,
        start: start,
        trimEnd: dur > room ? room : dur,
      ));
      _selection = Selection(SelectionKind.pip, _p.pips.length - 1);
      _commit();
    } catch (e) {
      _toast('Errore: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _recordVoice() async {
    if (_p.clips.isEmpty) return _toast('Aggiungi prima un video');
    await _pause();
    if (!mounted) return;
    final start = _clampToTotal(_position);
    _position = start;
    final path = await showVoiceSheet(
      context,
      onStart: () async {
        _recordingVoice = true;
        await _play();
      },
      onStop: () async {
        await _pause();
        _recordingVoice = false;
      },
    );
    if (path == null) return;
    try {
      final info = await _ffmpeg.probe(path);
      if (info.duration <= Duration.zero) return _toast('Registrazione vuota');
      _p.audios.add(AudioItem(path: path, start: start, duration: info.duration));
      _selection = Selection(SelectionKind.audio, _p.audios.length - 1);
      _position = start;
      _commit();
    } catch (e) {
      _toast('Errore: $e');
    }
  }

  Future<void> _addSound() async {
    if (_p.clips.isEmpty) return _toast('Aggiungi prima un video');
    await _pause();
    final res = await FilePicker.platform.pickFiles(type: FileType.audio);
    final picked = res?.files.single.path;
    if (picked == null) return;
    try {
      final path = await _keep(picked);
      final info = await _ffmpeg.probe(path);
      if (!info.hasAudio) return _toast('Il file non contiene audio');
      _p.audios.add(AudioItem(
        path: path,
        start: _clampToTotal(_position),
        duration: info.duration,
        isVoice: false,
      ));
      _selection = Selection(SelectionKind.audio, _p.audios.length - 1);
      _commit();
    } catch (e) {
      _toast('Errore: $e');
    }
  }

  Future<void> _applyTemplate() async {
    if (_p.clips.isEmpty) return _toast('Aggiungi prima qualche video o foto');
    await _pause();
    if (!mounted) return;
    final res = await showTemplateSheet(context, projectTemplates);
    if (res == null) return;
    res.$1.apply(_p, res.$2);
    _commit();
    _toast('Modello "${res.$1.name}" applicato');
  }

  Future<void> _toggleReverse() async {
    final i = _targetClip;
    final c = _p.clips[i];
    if (c.isImage) return _toast('Le foto non si possono invertire');
    await _pause();
    setState(() => _busy = c.reversed ? 'Ripristino la clip…' : 'Inverto la clip…');
    try {
      VideoClip next;
      if (!c.reversed) {
        if (c.trimEnd - c.trimStart > const Duration(seconds: 60)) {
          _toast('Per invertirla, taglia la clip sotto i 60 secondi');
          return;
        }
        final docs = await getApplicationDocumentsDirectory();
        final out = p.join(docs.path, 'media', 'rev_${DateTime.now().millisecondsSinceEpoch}.mp4');
        final ok = await _ffmpeg.reverse(c, out);
        if (ok == null) return _toast('Non sono riuscito a invertire la clip');
        final len = c.trimEnd - c.trimStart;
        next = VideoClip.fromJson({
          ...c.toJson(),
          'path': out,
          'sourceDuration': len.inMicroseconds,
          'trimStart': 0,
          'trimEnd': len.inMicroseconds,
          'reversed': true,
          'originalPath': c.originalPath ?? c.path,
          'bgMask': null,
        });
      } else {
        final orig = c.originalPath ?? c.path;
        final info = await _ffmpeg.probe(orig);
        next = VideoClip.fromJson({
          ...c.toJson(),
          'path': orig,
          'sourceDuration': info.duration.inMicroseconds,
          'trimStart': 0,
          'trimEnd': info.duration.inMicroseconds,
          'reversed': false,
          'originalPath': null,
          'bgMask': null,
        });
      }
      _p.clips[i] = next;
      _loadThumbs(next.path);
      _selection = Selection(SelectionKind.clip, i);
      _commit();
    } catch (e) {
      _toast('Errore: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _editPip(Future<bool?> Function(PipLayer l) sheet) async {
    await _pause();
    if (!mounted) return;
    await sheet(_p.pips[_selection.index]);
    _commit();
  }

  /// Attiva/disattiva il movimento (keyframe) di un testo o una sovrapposizione.
  Future<void> _motion() async {
    await _pause();
    if (!mounted) return;
    final isPip = _selection.kind == SelectionKind.pip;
    final pip = isPip ? _p.pips[_selection.index] : null;
    final ov = isPip ? null : _p.overlays[_selection.index];
    final enabled = (pip?.toCx ?? ov?.toCx) != null;
    await showMotionSheet(context, enabled: enabled, onChanged: (on) {
      if (pip != null) {
        pip.toCx = on ? (pip.cx > 0.5 ? pip.cx - 0.3 : pip.cx + 0.3) : null;
        pip.toCy = on ? pip.cy : null;
        pip.toScale = on ? pip.scale : null;
        pip.toRotation = on ? pip.rotation : null;
        if (on) pip.track = null;
      } else if (ov != null) {
        ov.toCx = on ? (ov.cx > 0.5 ? ov.cx - 0.3 : ov.cx + 0.3) : null;
        ov.toCy = on ? ov.cy : null;
        ov.toScale = on ? 1 : null;
        ov.toRotation = on ? ov.rotation : null;
        if (on) ov.track = null;
      }
    });
    _commit();
  }

  // ───────────────────────── Novità v0.4 ─────────────────────────

  /// Fermo immagine: divide la clip alla testina e inserisce 2 s di foto.
  Future<void> _freezeFrame() async {
    if (_p.clips.isEmpty) return;
    await _pause();
    final i = _targetClip;
    final c = _p.clips[i];
    final local = _position - _p.startOf(i);
    setState(() => _busy = 'Creo il fermo immagine…');
    try {
      String? jpg;
      if (c.isImage) {
        jpg = c.path;
      } else {
        final docs = await getApplicationDocumentsDirectory();
        final out = p.join(docs.path, 'media', 'freeze_${DateTime.now().millisecondsSinceEpoch}.jpg');
        await Directory(p.dirname(out)).create(recursive: true);
        jpg = await _ffmpeg.frameAt(c, local, out);
      }
      if (jpg == null) return _toast('Non riesco a leggere il fotogramma');
      final freeze = VideoClip.image(jpg, duration: const Duration(seconds: 2))
        ..effect = ClipEffect.none
        ..filter = c.filter
        ..adjust = c.adjust
        ..quarterTurns = c.quarterTurns
        ..cropZoom = c.cropZoom
        ..cropX = c.cropX
        ..cropY = c.cropY;
      _thumbs[jpg] = [jpg];
      final cut = c.sourceAt(local);
      const minLen = Duration(milliseconds: 200);
      if (!c.isImage && cut - c.trimStart > minLen && c.trimEnd - cut > minLen) {
        final second = c.copy()..trimStart = cut;
        c
          ..trimEnd = cut
          ..transition = TransitionType.none;
        _p.clips.insert(i + 1, freeze);
        _p.clips.insert(i + 2, second);
      } else {
        _p.clips.insert(i + 1, freeze);
      }
      _selection = Selection(SelectionKind.clip, i + 1);
      _commit();
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// Estrai audio: sposta l'audio della clip su una traccia separata.
  void _extractAudio() {
    final i = _targetClip;
    final c = _p.clips[i];
    if (!c.hasAudio || c.isImage) return _toast('Questa clip non ha audio');
    if ((c.speed - 1).abs() > 0.01 || c.speedCurve != SpeedCurve.none) {
      return _toast('Riporta la velocità a 1x prima di estrarre l\'audio');
    }
    _p.audios.add(AudioItem(
      path: c.path,
      start: _p.startOf(i),
      duration: c.trimEnd - c.trimStart,
      sourceStart: c.trimStart,
      volume: c.volume,
      isVoice: false,
    ));
    c.volume = 0;
    _selection = Selection(SelectionKind.audio, _p.audios.length - 1);
    _commit();
    _toast('Audio estratto: ora puoi spostarlo e modificarlo da solo');
  }

  /// Rimozione dello sfondo con l'IA (clip principale o sovrapposizione).
  Future<void> _removeBackground() async {
    await _pause();
    final isPip = _selection.kind == SelectionKind.pip;
    final pip = isPip ? _p.pips[_selection.index] : null;
    final clip = isPip ? null : _p.clips[_targetClip];
    final current = pip?.bgMask ?? clip?.bgMask;
    if (current != null) {
      pip?.bgMask = null;
      clip?.bgMask = null;
      _commit();
      return _toast('Sfondo ripristinato');
    }
    final path = pip?.path ?? clip!.path;
    final isImage = pip?.isImage ?? clip!.isImage;
    if (isImage) return _toast('Per ora la rimozione dello sfondo funziona sui video');
    final dur = pip?.sourceDuration ?? clip!.sourceDuration;
    if (dur > const Duration(minutes: 3)) return _toast('Video troppo lungo: massimo 3 minuti');
    if (clip != null && (clip.width <= 0 || clip.height <= 0)) {
      final info = await _ffmpeg.probe(clip.path);
      clip
        ..width = info.width
        ..height = info.height;
    }
    if (!mounted) return;
    var cancelled = false;
    final progress = ValueNotifier<double>(0);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Rimuovo lo sfondo'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, v, __) => Column(mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(value: v),
            const SizedBox(height: 12),
            Text('${(v * 100).round()}%'),
            const SizedBox(height: 4),
            const Text('L\'IA cerca le persone in ogni fotogramma.',
                style: TextStyle(fontSize: 12, color: Colors.white54)),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.of(ctx).pop();
            },
            child: const Text('Annulla'),
          ),
        ],
      ),
    );
    try {
      final mask = await _ai.removeBackground(path, dur,
          onProgress: (v) => progress.value = v, cancelled: () => cancelled);
      if (!mounted || cancelled) return;
      Navigator.of(context).pop();
      if (mask == null) return _toast('Non sono riuscito a trovare una persona nel video');
      pip?.bgMask = mask;
      clip?.bgMask = mask;
      _commit();
      _toast(isPip
          ? 'Sfondo rimosso: si vedrà nel video esportato'
          : 'Sfondo rimosso: dietro la persona c\'è lo sfondo scelto in "Formato"');
    } catch (e) {
      if (mounted && !cancelled) Navigator.of(context).pop();
      _toast('Errore: $e');
    } finally {
      progress.dispose();
    }
  }

  /// Tracciamento: l'elemento selezionato segue l'oggetto che ha sotto.
  Future<void> _trackSelected() async {
    await _pause();
    final isPip = _selection.kind == SelectionKind.pip;
    final pip = isPip ? _p.pips[_selection.index] : null;
    final ov = isPip ? null : _p.overlays[_selection.index];
    if ((pip?.track ?? ov?.track) != null) {
      pip?.track = null;
      ov?.track = null;
      _commit();
      return _toast('Tracciamento rimosso');
    }
    final start = pip?.start ?? ov!.start;
    final end = pip?.end ?? ov!.end;
    final ci = _p.clipIndexAt(start);
    final c = _p.clips[ci];
    if (c.isImage) return _toast('Il tracciamento funziona sopra un video');
    if (c.width <= 0 || c.height <= 0) {
      final info = await _ffmpeg.probe(c.path);
      c
        ..width = info.width
        ..height = info.height;
    }
    // Geometria della clip nel fotogramma finale (rotazione, ritaglio, adattamento).
    final odd = c.quarterTurns.isOdd;
    final sw = (odd ? c.height : c.width).toDouble(), sh = (odd ? c.width : c.height).toDouble();
    final vw = sw / c.cropZoom, vh = sh / c.cropZoom;
    final (bandTop, bandH) = _p.videoBand(_p.aspect.height);
    final cw = _p.aspect.width.toDouble(), ch = bandH.toDouble(), fullH = _p.aspect.height.toDouble();
    final sc = math.min(cw / vw, ch / vh);
    final ox = (cw - vw * sc) / 2, oy = (ch - vh * sc) / 2;
    final pos = (pip?.centerAt(start) ?? ov!.centerAt(start));
    final fx = ((pos.dx * cw - ox) / (vw * sc)).clamp(0.02, 0.98);
    final fy = ((pos.dy * fullH - bandTop - oy) / (vh * sc)).clamp(0.02, 0.98);

    final clipEnd = _p.startOf(ci) + c.outputDuration;
    final len = (end < clipEnd ? end : clipEnd) - start;
    if (len < const Duration(milliseconds: 500)) return _toast('L\'elemento è troppo corto per il tracciamento');

    final vf = <String>[
      if (c.quarterTurns % 4 == 1) 'transpose=1',
      if (c.quarterTurns % 4 == 2) 'hflip,vflip',
      if (c.quarterTurns % 4 == 3) 'transpose=2',
      if (c.hasCrop)
        "crop=w='trunc(iw/${c.cropZoom}/2)*2':h='trunc(ih/${c.cropZoom}/2)*2'"
            ":x='(iw-ow)*${0.5 + c.cropX / 2}':y='(ih-oh)*${0.5 + c.cropY / 2}'",
    ].join(',');

    setState(() => _busy = 'Seguo il movimento…');
    try {
      final path = await _ai.track(
        c.path,
        start: c.sourceAt(start - _p.startOf(ci)),
        duration: len,
        x: fx,
        y: fy,
        srcWidth: vw.round(),
        srcHeight: vh.round(),
        speed: c.speed,
        extraVf: vf,
      );
      if (path == null || path.length < 6) return _toast('Non sono riuscito a seguire l\'oggetto');
      // Coordinate della clip → coordinate del fotogramma finale.
      for (var k = 0; k + 2 < path.length; k += 3) {
        path[k + 1] = (ox + path[k + 1] * vw * sc) / cw;
        path[k + 2] = (bandTop + oy + path[k + 2] * vh * sc) / fullH;
      }
      if (pip != null) {
        pip
          ..track = path
          ..toCx = null
          ..toCy = null;
      } else {
        ov!
          ..track = path
          ..toCx = null
          ..toCy = null;
      }
      _commit();
      _toast('Fatto: l\'elemento segue l\'oggetto');
    } catch (e) {
      _toast('Errore: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  void _toggleStabilize() {
    final c = _p.clips[_targetClip];
    c.stabilize = !c.stabilize;
    _commit();
    _toast(c.stabilize ? 'Stabilizzazione attiva (nel video esportato)' : 'Stabilizzazione disattivata');
  }

  // ───────────────────────── Esportazione ─────────────────────────

  Future<void> _export() async {
    if (_p.clips.isEmpty) return _toast('Non c\'è niente da esportare');
    await _pause();
    if (!mounted) return;
    final go = await showExportSheet(context, _p);
    _history.commit(_p);
    if (go != true || !mounted) return;
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
    if (_p.clips.isEmpty || _clipIndex < 0) {
      return Center(
        child: FilledButton.tonalIcon(
          onPressed: _addClips,
          icon: const Icon(Icons.add_rounded),
          label: const Text('Aggiungi video o foto'),
        ),
      );
    }

    final i = _clipIndex.clamp(0, _p.clips.length - 1);
    final clip = _p.clips[i];
    final localS = math.max(0.0, (_position - _p.startOf(i)).inMicroseconds / 1e6);
    final durS = math.max(0.01, clip.outputDuration.inMicroseconds / 1e6);

    final c = _video;
    Widget media;
    if (clip.isImage) {
      media = Image.file(File(clip.path), gaplessPlayback: true);
    } else if (c != null && c.value.isInitialized) {
      media = SizedBox(width: c.value.size.width, height: c.value.size.height, child: VideoPlayer(c));
    } else {
      media = const SizedBox(width: 16, height: 9);
    }
    if (clip.quarterTurns % 4 != 0) media = RotatedBox(quarterTurns: clip.quarterTurns, child: media);
    if (clip.hasCrop) {
      media = ClipRect(
        child: Align(
          alignment: Alignment(clip.cropX, clip.cropY),
          widthFactor: 1 / clip.cropZoom,
          heightFactor: 1 / clip.cropZoom,
          child: media,
        ),
      );
    }

    final fg = FittedBox(fit: BoxFit.contain, child: media);
    final Widget bg = switch (_p.background) {
      CanvasBackground.black => const ColoredBox(color: Colors.black),
      CanvasBackground.white => const ColoredBox(color: Colors.white),
      CanvasBackground.blur => ClipRect(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: FittedBox(fit: BoxFit.cover, child: media),
          ),
        ),
    };

    Widget frame = clip.isImage && clip.motion != null
        ? KenBurnsView(path: clip.path, motion: clip.motion!, progress: (localS / durS).clamp(0.0, 1.0))
        : Stack(fit: StackFit.expand, children: [bg, fg]);
    if (!clip.adjust.isNeutral) {
      frame = ColorFiltered(colorFilter: ColorFilter.matrix(clip.adjust.matrix), child: frame);
    }
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
            onScaleStart: (d) => _gestureStart(d.localFocalPoint, size),
            onScaleUpdate: (d) => _gestureUpdate(d, size),
            onScaleEnd: (_) {
              if (_gActive) {
                _gActive = false;
                _commit();
              }
            },
            child: ClipRect(
              child: Stack(fit: StackFit.expand, children: [
                if (_p.meme) ...[
                  ColoredBox(color: _p.memeWhite ? Colors.white : Colors.black),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: size.height * _p.memeTop,
                    bottom: size.height * _p.memeBottom,
                    child: ClipRect(child: frame),
                  ),
                ] else
                  frame,
                for (var k = 0; k < _p.pips.length; k++)
                  if (_p.pips[k].visibleAt(_position)) _pipWidget(k, size),
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

  Rect _pipRect(PipLayer l, Size size) {
    final w = size.width * l.scaleAt(_position);
    final h = w * l.height / l.width;
    final c = l.centerAt(_position);
    return Rect.fromCenter(center: Offset(c.dx * size.width, c.dy * size.height), width: w, height: h);
  }

  Widget _pipWidget(int k, Size size) {
    final l = _p.pips[k];
    final r = _pipRect(l, size);
    Widget content;
    if (l.isImage) {
      content = Image.file(File(l.path), fit: BoxFit.cover, gaplessPlayback: true);
    } else {
      final c = _layers.controllerFor(l);
      content = c == null
          ? const ColoredBox(color: Colors.black26)
          : FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(width: c.value.size.width, height: c.value.size.height, child: VideoPlayer(c)),
            );
    }
    if (l.mask != MaskShape.none) content = ClipPath(clipper: MaskClipper(l.mask), child: content);
    final selected = _selection.isPip(k);
    return Positioned.fromRect(
      rect: r,
      child: IgnorePointer(
        child: Transform.rotate(
          angle: l.rotationAt(_position),
          child: Opacity(
          opacity: l.opacity,
          child: Stack(fit: StackFit.expand, children: [
            content,
            if (selected)
              DecoratedBox(decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 1.5))),
            if (l.chroma != null || l.bgMask != null)
              const Positioned(
                left: 4,
                top: 4,
                child: Icon(Icons.auto_fix_high_rounded, size: 14, color: Colors.white70),
              ),
          ]),
          ),
        ),
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
      case ClipEffect.spotlight:
      case ClipEffect.glint:
        return Stack(fit: StackFit.expand, children: [
          child,
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [Colors.transparent, Color(0xE6000000)],
                stops: [0.45, 1.0],
                radius: 0.85,
              ),
            ),
          ),
        ]);
    }
  }

  /// Elemento sotto il dito: prima testi/sticker (stanno sopra), poi
  /// le sovrapposizioni.
  Selection? _hit(Offset pos, Size size) {
    final scale = size.width / _p.aspect.width;
    final t = _position.inMicroseconds / 1e6;
    for (var i = _p.overlays.length - 1; i >= 0; i--) {
      final o = _p.overlays[i];
      if (!o.visibleAt(_position)) continue;
      final a = o.animAt(t);
      final base = o.centerAt(_position);
      final l = OverlayLayout(o, scale: scale, frameWidth: _p.aspect.width);
      final r = Rect.fromCenter(
        center: Offset((base.dx + a.dx) * size.width, (base.dy + a.dy) * size.height),
        width: l.size.width + 24,
        height: l.size.height + 24,
      );
      if (r.contains(pos)) return Selection(SelectionKind.overlay, i);
    }
    for (var k = _p.pips.length - 1; k >= 0; k--) {
      final l = _p.pips[k];
      if (l.visibleAt(_position) && _pipRect(l, size).contains(pos)) {
        return Selection(SelectionKind.pip, k);
      }
    }
    return null;
  }

  void _tapPreview(Offset pos, Size size) {
    final hit = _hit(pos, size);
    if (hit != null) {
      if (hit == _selection && hit.kind == SelectionKind.overlay) {
        final o = _p.overlays[hit.index];
        if (o.kind != OverlayKind.sticker) _addOrEditText(hit.index);
      } else {
        _pause();
        setState(() => _selection = hit);
      }
      return;
    }
    _playing ? _pause() : _play();
  }

  bool get _selVisible => switch (_selection.kind) {
        SelectionKind.overlay => _p.overlays[_selection.index].visibleAt(_position),
        SelectionKind.pip => _p.pips[_selection.index].visibleAt(_position),
        _ => false,
      };

  void _gestureStart(Offset focal, Size size) {
    final hit = _hit(focal, size);
    if (hit != null) _selection = hit;
    if (!_selVisible) {
      _gActive = false;
      return;
    }
    if (_playing) _pause();
    _gActive = true;
    _gFocal = focal;
    double? toCx, toCy;
    Duration start, end;
    if (_selection.kind == SelectionKind.overlay) {
      final o = _p.overlays[_selection.index];
      _gFont = o.fontSize;
      _gRot = o.rotation;
      _gToScale = o.toScale ?? 1;
      _gToRot = o.toRotation ?? o.rotation;
      toCx = o.toCx;
      toCy = o.toCy;
      start = o.start;
      end = o.end;
      _gCx = o.cx;
      _gCy = o.cy;
    } else {
      final l = _p.pips[_selection.index];
      _gScale = l.scale;
      _gRot = l.rotation;
      _gToScale = l.toScale ?? l.scale;
      _gToRot = l.toRotation ?? l.rotation;
      toCx = l.toCx;
      toCy = l.toCy;
      start = l.start;
      end = l.end;
      _gCx = l.cx;
      _gCy = l.cy;
    }
    // Con il movimento attivo, nella seconda metà si sposta il punto d'arrivo.
    final mid = start + (end - start) ~/ 2;
    _gEditEnd = toCx != null && _position >= mid;
    if (_gEditEnd) {
      _gCx = toCx!;
      _gCy = toCy ?? _gCy;
    }
    setState(() {});
  }

  void _gestureUpdate(ScaleUpdateDetails d, Size size) {
    if (!_gActive) return;
    final delta = d.localFocalPoint - _gFocal;
    final nx = (_gCx + delta.dx / size.width).clamp(-0.2, 1.2);
    final ny = (_gCy + delta.dy / size.height).clamp(-0.2, 1.2);
    setState(() {
      if (_selection.kind == SelectionKind.overlay) {
        final o = _p.overlays[_selection.index];
        if (_gEditEnd) {
          o.toCx = nx;
          o.toCy = ny;
        } else {
          o.cx = nx;
          o.cy = ny;
        }
        if (d.pointerCount > 1) {
          if (_gEditEnd) {
            o.toScale = (_gToScale * d.scale).clamp(0.1, 8.0);
            o.toRotation = _gToRot + d.rotation;
          } else {
            o.fontSize = (_gFont * d.scale).clamp(20.0, 600.0);
            o.rotation = _gRot + d.rotation;
          }
        }
      } else {
        final l = _p.pips[_selection.index];
        if (_gEditEnd) {
          l.toCx = nx;
          l.toCy = ny;
        } else {
          l.cx = nx;
          l.cy = ny;
        }
        if (d.pointerCount > 1) {
          if (_gEditEnd) {
            l.toScale = (_gToScale * d.scale).clamp(0.08, 1.6);
            l.toRotation = _gToRot + d.rotation;
          } else {
            l.scale = (_gScale * d.scale).clamp(0.08, 1.6);
            l.rotation = _gRot + d.rotation;
          }
        }
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
    Future<void> format() async {
      await _pause();
      if (!mounted) return;
      await showFormatSheet(context, _p);
      _commit();
    }

    switch (_selection.kind) {
      case SelectionKind.none:
      case SelectionKind.transition:
        items.addAll([
          _Tool(Icons.content_cut_rounded, 'Dividi', _p.clips.isEmpty ? null : _splitClip),
          _Tool(Icons.sentiment_very_satisfied_rounded, 'Meme', _openMeme),
          _Tool(Icons.dashboard_customize_rounded, 'Modelli', _applyTemplate),
          _Tool(Icons.music_note_rounded, 'Musica', _addMusic),
          _Tool(Icons.mic_rounded, 'Voce', _recordVoice),
          _Tool(Icons.graphic_eq_rounded, 'Suoni', _addSound),
          _Tool(Icons.title_rounded, 'Testo', () => _addOrEditText()),
          _Tool(Icons.emoji_emotions_rounded, 'Sticker', _addSticker),
          _Tool(Icons.picture_in_picture_alt_rounded, 'Sovrapponi', _addPip),
          _Tool(Icons.subtitles_rounded, 'Sottotitoli', _autoSubtitles),
          _Tool(Icons.auto_awesome_rounded, 'Effetti', () => _editClip((c) => showEffectSheet(context, c))),
          _Tool(Icons.filter_vintage_rounded, 'Filtri', () => _editClip((c) => showFilterSheet(context, c, applyToAll: _filterAll(c)))),
          _Tool(Icons.aspect_ratio_rounded, 'Formato', format),
        ]);
      case SelectionKind.clip:
        final clip = _p.clips[_selection.index];
        items.addAll([
          _Tool(Icons.content_cut_rounded, 'Dividi', _splitClip),
          if (clip.isImage)
            _Tool(Icons.timer_rounded, 'Durata', () => _editClip((c) => showImageDurationSheet(context, c)))
          else
            _Tool(Icons.speed_rounded, 'Velocità', () => _editClip((c) => showSpeedSheet(context, c))),
          if (!clip.isImage)
            _Tool(Icons.show_chart_rounded, 'Curva', () => _editClip((c) => showSpeedCurveSheet(context, c))),
          _Tool(Icons.auto_awesome_rounded, 'Effetti', () => _editClip((c) => showEffectSheet(context, c))),
          _Tool(Icons.tune_rounded, 'Regola', () => _editClip((c) => showAdjustSheet(context, c,
              onLive: () => setState(() {}),
              applyToAll: () {
                for (final x in _p.clips) {
                  x.adjust = c.adjust;
                }
                Navigator.pop(context, true);
              }))),
          _Tool(Icons.crop_free_rounded, 'Ritaglia', () => _editClip((c) => showCropSheet(context, c, onLive: () => setState(() {})))),
          _Tool(Icons.pause_presentation_rounded, 'Fermo immagine', _freezeFrame),
          if (!clip.isImage) ...[
            _Tool(clip.bgMask != null ? Icons.person_off_rounded : Icons.person_remove_rounded,
                clip.bgMask != null ? 'Ripristina sfondo' : 'Rimuovi sfondo', _removeBackground),
            _Tool(Icons.video_stable_rounded, clip.stabilize ? 'Stabile ✓' : 'Stabilizza', _toggleStabilize),
          ],
          if (clip.hasAudio && !clip.isImage) ...[
            _Tool(Icons.call_split_rounded, 'Estrai audio', _extractAudio),
            _Tool(Icons.graphic_eq_rounded, 'Dissolvenza', () => _editClip((c) => showAudioFadeSheet(context,
                fadeIn: c.fadeIn, fadeOut: c.fadeOut, onChanged: (a, b) {
                  c.fadeIn = a;
                  c.fadeOut = b;
                }))),
          ],
          _Tool(Icons.filter_vintage_rounded, 'Filtri', () => _editClip((c) => showFilterSheet(context, c, applyToAll: _filterAll(c)))),
          _Tool(Icons.rotate_right_rounded, 'Ruota', () => _editClip((c) => showRotateSheet(context, c))),
          if (!clip.isImage)
            _Tool(clip.reversed ? Icons.restore_rounded : Icons.fast_rewind_rounded,
                clip.reversed ? 'Originale' : 'Al contrario', _toggleReverse),
          if (clip.hasAudio && !clip.isImage) ...[
            _Tool(Icons.volume_up_rounded, 'Volume', () => _editClip((c) => showVolumeSheet(context,
                title: 'Volume clip', value: c.volume, onChanged: (v) => c.volume = v))),
            _Tool(Icons.record_voice_over_rounded, 'Effetti voce', () => _editClip((c) => showAudioFxSheet(context,
                value: c.voiceFx, denoise: c.denoise, onChanged: (fx, dn) {
                  c.voiceFx = fx;
                  c.denoise = dn;
                }))),
          ],
          if (!clip.isImage)
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
        items.add(_Tool(Icons.moving_rounded, 'Movimento', _motion));
        items.add(_Tool(Icons.my_location_rounded, o.track != null ? 'Togli tracciamento' : 'Traccia', _trackSelected));
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
      case SelectionKind.pip:
        final l = _p.pips[_selection.index];
        items.addAll([
          _Tool(Icons.interests_rounded, 'Maschera', () => _editPip((l) => showMaskSheet(context, l))),
          _Tool(Icons.format_color_reset_rounded, 'Chroma key', () => _editPip((l) => showChromaSheet(context, l))),
          if (!l.isImage)
            _Tool(l.bgMask != null ? Icons.person_off_rounded : Icons.person_remove_rounded,
                l.bgMask != null ? 'Ripristina sfondo' : 'Rimuovi sfondo', _removeBackground),
          _Tool(Icons.my_location_rounded, l.track != null ? 'Togli tracciamento' : 'Traccia', _trackSelected),
          _Tool(Icons.opacity_rounded, 'Opacità', () => _editPip((l) => showOpacitySheet(context, l))),
          _Tool(Icons.moving_rounded, 'Movimento', _motion),
          if (l.hasAudio)
            _Tool(Icons.volume_up_rounded, 'Volume', () => _editPip((l) => showVolumeSheet(context,
                title: 'Volume sovrapposizione', value: l.volume, onChanged: (v) => l.volume = v))),
          _Tool(Icons.copy_rounded, 'Duplica', () {
            _p.pips.add(l.copy()..cx = (l.cx + 0.08).clamp(0.0, 1.0));
            _selection = Selection(SelectionKind.pip, _p.pips.length - 1);
            _commit();
          }),
          _Tool(Icons.delete_outline_rounded, 'Elimina', _deleteSelected),
        ]);
      case SelectionKind.audio:
        final a = _p.audios[_selection.index];
        items.addAll([
          _Tool(Icons.volume_up_rounded, 'Volume', () async {
            await _pause();
            if (!mounted) return;
            await showVolumeSheet(context, title: 'Volume', value: a.volume, onChanged: (v) => a.volume = v);
            _commit();
          }),
          _Tool(Icons.record_voice_over_rounded, 'Effetti voce', () async {
            await _pause();
            if (!mounted) return;
            await showAudioFxSheet(context, value: a.fx, denoise: a.denoise, onChanged: (fx, dn) {
              a.fx = fx;
              a.denoise = dn;
            });
            _commit();
          }),
          _Tool(Icons.graphic_eq_rounded, 'Dissolvenza', () async {
            await _pause();
            if (!mounted) return;
            await showAudioFadeSheet(context, fadeIn: a.fadeIn, fadeOut: a.fadeOut, onChanged: (x, y) {
              a.fadeIn = x;
              a.fadeOut = y;
            });
            _commit();
          }),
          _Tool(Icons.delete_outline_rounded, 'Elimina', _deleteSelected),
        ]);
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
