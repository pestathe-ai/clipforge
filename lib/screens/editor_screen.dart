import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:video_player/video_player.dart';

import '../models/project.dart';
import '../services/ffmpeg_service.dart';
import '../widgets/edit_sheets.dart';
import '../widgets/timeline.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.project});
  final Project project;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final _ffmpeg = FFmpegService();
  Project get _p => widget.project;

  VideoPlayerController? _video;
  VideoPlayerController? _musicPlayer;
  int _clipIndex = 0;
  bool _playing = false;
  bool _importing = false;
  bool _switching = false; // evita cambi clip multipli mentre carica
  Duration _position = Duration.zero; // posizione sulla timeline finale
  Selection _selection = const Selection.none();

  @override
  void dispose() {
    _video?.dispose();
    _musicPlayer?.dispose();
    super.dispose();
  }

  // ───────────────────────── Riproduzione ─────────────────────────

  /// Carica la clip che contiene l'istante [t] della timeline finale.
  Future<void> _seek(Duration t, {bool keepPlaying = false}) async {
    if (_p.clips.isEmpty) {
      final old = _video;
      setState(() {
        _video = null;
        _position = Duration.zero;
      });
      await old?.dispose();
      return;
    }
    final total = _p.totalDuration;
    if (t > total) t = total;
    if (t < Duration.zero) t = Duration.zero;

    var index = _p.clips.length - 1;
    for (var i = 0; i < _p.clips.length; i++) {
      if (t < _p.startOf(i) + _p.clips[i].outputDuration) {
        index = i;
        break;
      }
    }
    final clip = _p.clips[index];
    final local = t - _p.startOf(index);
    final sourcePos = clip.trimStart +
        Duration(microseconds: (local.inMicroseconds * clip.speed).round());

    if (_video == null || index != _clipIndex) {
      _switching = true;
      try {
        final old = _video;
        old?.removeListener(_onTick);
        final c = VideoPlayerController.file(File(clip.path));
        await c.initialize();
        c.addListener(_onTick);
        _video = c;
        _clipIndex = index;
        await old?.dispose();
      } finally {
        _switching = false;
      }
    }
    final c = _video!;
    await c.setPlaybackSpeed(clip.speed);
    await c.setVolume(clip.volume.clamp(0.0, 1.0));
    await c.seekTo(sourcePos);
    final music = _p.music;
    if (music != null && _musicPlayer != null && music.duration > Duration.zero) {
      final m = (music.offset + t).inMicroseconds % music.duration.inMicroseconds;
      await _musicPlayer!.seekTo(Duration(microseconds: m));
    }
    if (keepPlaying || _playing) {
      await c.play();
      await _musicPlayer?.play();
    }
    if (mounted) setState(() => _position = t);
  }

  void _onTick() {
    final c = _video;
    if (c == null || !mounted || _switching) return;
    if (_clipIndex < 0 || _clipIndex >= _p.clips.length) return;
    final clip = _p.clips[_clipIndex];
    final pos = c.value.position;
    final local = Duration(
      microseconds:
          ((pos - clip.trimStart).inMicroseconds / clip.speed).round(),
    );
    final t = _p.startOf(_clipIndex) + local;

    if (_playing && pos >= clip.trimEnd) {
      if (_clipIndex + 1 < _p.clips.length) {
        _seek(_p.startOf(_clipIndex + 1), keepPlaying: true);
      } else {
        _pause();
        _seek(Duration.zero);
      }
      return;
    }
    if (_playing) setState(() => _position = t);
  }

  Future<void> _play() async {
    if (_p.clips.isEmpty) return;
    setState(() => _playing = true);
    if (_position >= _p.totalDuration) {
      await _seek(Duration.zero, keepPlaying: true);
    } else {
      await _seek(_position, keepPlaying: true);
    }
  }

  Future<void> _pause() async {
    setState(() => _playing = false);
    await _video?.pause();
    await _musicPlayer?.pause();
  }

  /// Dopo una modifica a clip o durata: ricarica la clip e riposiziona.
  Future<void> _refresh() async {
    await _pause();
    _clipIndex = -1;
    await _seek(_position);
  }

  // ───────────────────────── Importazione ─────────────────────────

  Future<void> _addClips() async {
    final res = await FilePicker.platform
        .pickFiles(type: FileType.video, allowMultiple: true);
    if (res == null) return;
    setState(() => _importing = true);
    try {
      for (final f in res.files) {
        final path = f.path;
        if (path == null) continue;
        final info = await _ffmpeg.probe(path);
        if (!info.hasVideo || info.duration <= Duration.zero) {
          _toast('${f.name}: nessuna traccia video trovata');
          continue;
        }
        _p.clips.add(VideoClip(
          path: path,
          sourceDuration: info.duration,
          hasAudio: info.hasAudio,
        ));
      }
    } catch (e) {
      _toast('Errore durante l\'importazione: $e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
    await _refresh();
  }

  Future<void> _addMusic() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.audio);
    final path = res?.files.single.path;
    if (path == null) return;
    try {
      final info = await _ffmpeg.probe(path);
      if (!info.hasAudio) {
        _toast('Il file non contiene audio');
        return;
      }
      await _musicPlayer?.dispose();
      final m = VideoPlayerController.file(File(path));
      await m.initialize();
      await m.setLooping(true);
      _musicPlayer = m;
      setState(() =>
          _p.music = MusicTrack(path: path, duration: info.duration));
      await m.setVolume(_p.music!.volume.clamp(0.0, 1.0));
      await _refresh();
    } catch (e) {
      _toast('Impossibile aprire il brano: $e');
    }
  }

  // ───────────────────────── Modifiche ─────────────────────────

  Future<void> _editClip(Future<bool?> Function(VideoClip) sheet) async {
    final i = _selection.index;
    await _pause();
    if (!mounted) return;
    await sheet(_p.clips[i]);
    _clampTexts();
    await _refresh();
  }

  void _clampTexts() {
    final total = _p.totalDuration;
    _p.texts.removeWhere((t) => t.start >= total);
    for (final t in _p.texts) {
      if (t.end > total) t.end = total;
    }
  }

  void _moveClip(int delta) {
    final i = _selection.index;
    final j = i + delta;
    if (j < 0 || j >= _p.clips.length) return;
    setState(() {
      final c = _p.clips.removeAt(i);
      _p.clips.insert(j, c);
      _selection = Selection(SelectionKind.clip, j);
    });
    _refresh();
  }

  void _splitClip() {
    final i = _selection.index;
    final clip = _p.clips[i];
    final local = _position - _p.startOf(i);
    final cut = clip.trimStart +
        Duration(microseconds: (local.inMicroseconds * clip.speed).round());
    const minLen = Duration(milliseconds: 200);
    if (cut - clip.trimStart < minLen || clip.trimEnd - cut < minLen) {
      _toast('Sposta la testina dentro la clip selezionata');
      return;
    }
    final second = VideoClip(
      path: clip.path,
      sourceDuration: clip.sourceDuration,
      hasAudio: clip.hasAudio,
      trimStart: cut,
      trimEnd: clip.trimEnd,
      speed: clip.speed,
      filter: clip.filter,
      volume: clip.volume,
    );
    setState(() {
      clip.trimEnd = cut;
      _p.clips.insert(i + 1, second);
    });
    _refresh();
  }

  void _deleteSelected() {
    setState(() {
      switch (_selection.kind) {
        case SelectionKind.clip:
          _p.clips.removeAt(_selection.index);
          _clampTexts();
        case SelectionKind.text:
          _p.texts.removeAt(_selection.index);
        case SelectionKind.music:
          _p.music = null;
          _musicPlayer?.dispose();
          _musicPlayer = null;
        case SelectionKind.none:
          break;
      }
      _selection = const Selection.none();
    });
    _refresh();
  }

  Future<void> _addOrEditText({TextOverlay? existing, int? index}) async {
    if (_p.clips.isEmpty) {
      _toast('Aggiungi prima una clip');
      return;
    }
    await _pause();
    if (!mounted) return;
    final result = await showTextSheet(
      context,
      total: _p.totalDuration,
      at: _position,
      existing: existing,
    );
    if (result == null) return;
    setState(() {
      if (index != null) {
        _p.texts[index] = result;
      } else {
        _p.texts.add(result);
        _selection = Selection(SelectionKind.text, _p.texts.length - 1);
      }
    });
  }

  // ───────────────────────── Esportazione ─────────────────────────

  Future<void> _export() async {
    if (_p.clips.isEmpty) {
      _toast('Non c\'è niente da esportare');
      return;
    }
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
          ]),
        ),
        actions: [
          TextButton(onPressed: _ffmpeg.cancel, child: const Text('Annulla')),
        ],
      ),
    );

    try {
      final out = await _ffmpeg.export(_p, onProgress: (v) => progress.value = v);
      if (!mounted) return;
      Navigator.of(context).pop();
      var saved = false;
      try {
        if (!await Gal.hasAccess(toAlbum: true)) {
          await Gal.requestAccess(toAlbum: true);
        }
        await Gal.putVideo(out, album: 'ClipForge');
        saved = true;
      } catch (_) {}
      _toast(saved
          ? 'Video salvato nella galleria'
          : 'Video esportato in: $out');
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
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text('${fmt(_position)} / ${fmt(_p.totalDuration)}',
            style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _export,
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              label: const Text('Esporta'),
            ),
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
            selection: _selection,
            onSeek: (t) => _seek(t),
            onSelect: (s) => setState(() => _selection = s),
          ),
          const SizedBox(height: 8),
          _toolbar(),
        ],
      ),
    );
  }

  Widget _preview() {
    if (_importing) {
      return const Center(child: CircularProgressIndicator());
    }
    final c = _video;
    if (c == null || !c.value.isInitialized) {
      return Center(
        child: FilledButton.tonalIcon(
          onPressed: _addClips,
          icon: const Icon(Icons.add_rounded),
          label: const Text('Aggiungi video'),
        ),
      );
    }
    final clip = _p.clips[_clipIndex.clamp(0, _p.clips.length - 1)];
    final matrix = clip.filter.previewMatrix;
    Widget player = FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: c.value.size.width,
        height: c.value.size.height,
        child: VideoPlayer(c),
      ),
    );
    if (matrix != null) {
      player = ColorFiltered(colorFilter: ColorFilter.matrix(matrix), child: player);
    }

    return Center(
      child: AspectRatio(
        aspectRatio: _p.aspect.ratio,
        child: LayoutBuilder(builder: (context, box) {
          final scale = box.maxWidth / _p.aspect.width;
          return ClipRect(
            child: Stack(fit: StackFit.expand, children: [
              const ColoredBox(color: Colors.black),
              player,
              for (final t in _p.texts)
                if (_position >= t.start && _position <= t.end)
                  _textPreview(t, scale),
            ]),
          );
        }),
      ),
    );
  }

  Widget _textPreview(TextOverlay t, double scale) {
    final align = switch (t.position) {
      TextPosition.top => const Alignment(0, -0.84),
      TextPosition.center => Alignment.center,
      TextPosition.bottom => const Alignment(0, 0.7),
    };
    return Align(
      alignment: align,
      child: Container(
        padding: EdgeInsets.all(24 * scale),
        color: t.box ? Colors.black.withValues(alpha: 0.45) : null,
        child: Text(
          t.text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Poppins',
            fontWeight: FontWeight.w700,
            fontSize: t.fontSize * scale,
            color: t.color,
            shadows: t.box
                ? null
                : const [Shadow(blurRadius: 3, color: Colors.black)],
          ),
        ),
      ),
    );
  }

  Widget _transport() {
    return IconButton(
      iconSize: 36,
      onPressed: _p.clips.isEmpty ? null : (_playing ? _pause : _play),
      icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
    );
  }

  Widget _toolbar() {
    final items = <_Tool>[];
    switch (_selection.kind) {
      case SelectionKind.none:
        items.addAll([
          _Tool(Icons.video_library_rounded, 'Clip', _addClips),
          _Tool(Icons.title_rounded, 'Testo', () => _addOrEditText()),
          _Tool(Icons.music_note_rounded, 'Musica', _addMusic),
        ]);
      case SelectionKind.clip:
        final clip = _p.clips[_selection.index];
        items.addAll([
          _Tool(Icons.content_cut_rounded, 'Dividi', _splitClip),
          _Tool(Icons.crop_rounded, 'Taglia',
              () => _editClip((c) => showTrimSheet(context, c))),
          _Tool(Icons.speed_rounded, 'Velocità',
              () => _editClip((c) => showSpeedSheet(context, c))),
          _Tool(Icons.auto_awesome_rounded, 'Filtro',
              () => _editClip((c) => showFilterSheet(context, c))),
          _Tool(Icons.volume_up_rounded, 'Volume', () => _editClip(
                (c) => showVolumeSheet(context,
                    title: 'Volume clip',
                    value: c.volume,
                    onChanged: (v) => c.volume = v),
              )),
          _Tool(Icons.arrow_back_rounded, 'Sposta', () => _moveClip(-1)),
          _Tool(Icons.arrow_forward_rounded, 'Sposta', () => _moveClip(1)),
          _Tool(Icons.delete_outline_rounded, 'Elimina', _deleteSelected),
        ]);
        if (!clip.hasAudio) items.removeAt(4);
      case SelectionKind.text:
        final i = _selection.index;
        items.addAll([
          _Tool(Icons.edit_rounded, 'Modifica',
              () => _addOrEditText(existing: _p.texts[i], index: i)),
          _Tool(Icons.delete_outline_rounded, 'Elimina', _deleteSelected),
        ]);
      case SelectionKind.music:
        items.addAll([
          _Tool(Icons.volume_up_rounded, 'Volume', () async {
            await showVolumeSheet(context,
                title: 'Volume musica',
                value: _p.music!.volume,
                onChanged: (v) {
                  _p.music!.volume = v;
                  _musicPlayer?.setVolume(v.clamp(0.0, 1.0));
                });
          }),
          _Tool(Icons.delete_outline_rounded, 'Rimuovi', _deleteSelected),
        ]);
    }

    return SafeArea(
      top: false,
      child: SizedBox(
        height: 72,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            for (final t in items)
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: t.onTap,
                child: SizedBox(
                  width: 72,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(t.icon),
                      const SizedBox(height: 4),
                      Text(t.label, style: const TextStyle(fontSize: 11)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Tool {
  _Tool(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}
