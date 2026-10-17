import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

/// Un elemento con un proprio player nell'anteprima (sovrapposizione video,
/// voce fuori campo, effetto sonoro).
class LayerEntry {
  LayerEntry({
    required this.key,
    required this.path,
    required this.start,
    required this.sourceStart,
    required this.duration,
    this.volume = 1.0,
  });

  /// Oggetto del modello (identità usata come chiave).
  final Object key;
  final String path;
  final Duration start;
  final Duration sourceStart;
  final Duration duration;
  final double volume;

  bool visibleAt(Duration t) => t >= start && t < start + duration;
}

/// Gestisce i player secondari dell'anteprima e li tiene sincronizzati
/// con la testina.
class LayerPlayers extends ChangeNotifier {
  final _players = <Object, VideoPlayerController>{};
  final _loading = <Object>{};
  Set<Object> _visible = {};

  VideoPlayerController? controllerFor(Object key) {
    final c = _players[key];
    return c != null && c.value.isInitialized ? c : null;
  }

  /// true se l'insieme degli elementi visibili è cambiato da [lastSync].
  bool visibilityChanged(List<LayerEntry> entries, Duration t) {
    final now = {for (final e in entries) if (e.visibleAt(t)) e.key};
    return !setEquals(now, _visible);
  }

  Future<void> sync(List<LayerEntry> entries, Duration t, {required bool playing}) async {
    final keys = entries.map((e) => e.key).toSet();
    // Libera i player di elementi eliminati.
    for (final k in _players.keys.where((k) => !keys.contains(k)).toList()) {
      _players.remove(k)?.dispose();
    }
    _visible = {for (final e in entries) if (e.visibleAt(t)) e.key};

    for (final e in entries) {
      final visible = e.visibleAt(t);
      var c = _players[e.key];
      if (c == null) {
        if (!visible || _loading.contains(e.key)) continue;
        _loading.add(e.key);
        c = VideoPlayerController.file(File(e.path));
        try {
          await c.initialize();
        } catch (_) {
          _loading.remove(e.key);
          continue;
        }
        _loading.remove(e.key);
        if (!keys.contains(e.key)) {
          await c.dispose();
          continue;
        }
        _players[e.key] = c;
        notifyListeners();
      }
      if (visible) {
        await c.setVolume(e.volume.clamp(0.0, 1.0));
        await c.seekTo(e.sourceStart + (t - e.start));
        if (playing) {
          await c.play();
        } else {
          await c.pause();
        }
      } else if (c.value.isPlaying) {
        await c.pause();
      }
    }
  }

  Future<void> pauseAll() async {
    for (final c in _players.values) {
      if (c.value.isPlaying) await c.pause();
    }
  }

  @override
  void dispose() {
    for (final c in _players.values) {
      c.dispose();
    }
    _players.clear();
    super.dispose();
  }
}
