import 'package:flutter/material.dart';

/// Filtri colore disponibili. Ognuno ha un filtro FFmpeg per l'export
/// e una matrice colore per l'anteprima in-app.
enum VideoFilter {
  none('Nessuno', null),
  mono('B/N', 'hue=s=0'),
  sepia(
    'Seppia',
    'colorchannelmixer=.393:.769:.189:0:.349:.686:.168:0:.272:.534:.131',
  ),
  vivid('Vivace', 'eq=saturation=1.6'),
  contrast('Contrasto', 'eq=contrast=1.35:brightness=0.02'),
  cool('Freddo', 'colorbalance=bs=0.25:bm=0.15:rs=-0.1');

  const VideoFilter(this.label, this.ffmpeg);
  final String label;
  final String? ffmpeg;

  /// Matrice 4x5 per [ColorFilter.matrix], usata solo per l'anteprima.
  List<double>? get previewMatrix {
    switch (this) {
      case VideoFilter.none:
        return null;
      case VideoFilter.mono:
        return const [
          0.2126, 0.7152, 0.0722, 0, 0, //
          0.2126, 0.7152, 0.0722, 0, 0,
          0.2126, 0.7152, 0.0722, 0, 0,
          0, 0, 0, 1, 0,
        ];
      case VideoFilter.sepia:
        return const [
          0.393, 0.769, 0.189, 0, 0, //
          0.349, 0.686, 0.168, 0, 0,
          0.272, 0.534, 0.131, 0, 0,
          0, 0, 0, 1, 0,
        ];
      case VideoFilter.vivid:
        const s = 1.6;
        const r = 0.2126 * (1 - s), g = 0.7152 * (1 - s), b = 0.0722 * (1 - s);
        return const [
          r + s, g, b, 0, 0, //
          r, g + s, b, 0, 0,
          r, g, b + s, 0, 0,
          0, 0, 0, 1, 0,
        ];
      case VideoFilter.contrast:
        const c = 1.35, t = (1 - c) * 128 + 5;
        return const [
          c, 0, 0, 0, t, //
          0, c, 0, 0, t,
          0, 0, c, 0, t,
          0, 0, 0, 1, 0,
        ];
      case VideoFilter.cool:
        return const [
          0.9, 0, 0, 0, 0, //
          0, 1.0, 0, 0, 10,
          0, 0, 1.2, 0, 25,
          0, 0, 0, 1, 0,
        ];
    }
  }
}

/// Una clip video sulla traccia principale.
class VideoClip {
  VideoClip({
    required this.path,
    required this.sourceDuration,
    required this.hasAudio,
    Duration? trimStart,
    Duration? trimEnd,
    this.speed = 1.0,
    this.filter = VideoFilter.none,
    this.volume = 1.0,
  })  : trimStart = trimStart ?? Duration.zero,
        trimEnd = trimEnd ?? sourceDuration;

  final String path;
  final Duration sourceDuration;
  final bool hasAudio;
  Duration trimStart;
  Duration trimEnd;

  /// Velocità di riproduzione, limitata a 0.5–2.0 (range di `atempo`).
  double speed;
  VideoFilter filter;

  /// Volume dell'audio originale della clip (0–2).
  double volume;

  /// Durata della clip nel video finale, dopo taglio e velocità.
  Duration get outputDuration => Duration(
        microseconds:
            ((trimEnd - trimStart).inMicroseconds / speed).round(),
      );
}

/// Testo sovrapposto al video in un intervallo di tempo.
class TextOverlay {
  TextOverlay({
    required this.text,
    required this.start,
    required this.end,
    this.color = Colors.white,
    this.fontSize = 64,
    this.position = TextPosition.bottom,
    this.box = true,
  });

  String text;
  Duration start;
  Duration end;
  Color color;

  /// Dimensione in pixel sul video esportato (1080x1920).
  double fontSize;
  TextPosition position;

  /// Riquadro semitrasparente dietro al testo.
  bool box;
}

enum TextPosition {
  top('Alto'),
  center('Centro'),
  bottom('Basso');

  const TextPosition(this.label);
  final String label;
}

/// Traccia musicale di sottofondo.
class MusicTrack {
  MusicTrack({
    required this.path,
    required this.duration,
    this.volume = 0.6,
    this.offset = Duration.zero,
  });

  final String path;
  final Duration duration;
  double volume;

  /// Da che punto del brano partire.
  Duration offset;
}

/// Formato di uscita.
enum AspectRatioPreset {
  portrait('9:16', 1080, 1920),
  square('1:1', 1080, 1080),
  landscape('16:9', 1920, 1080);

  const AspectRatioPreset(this.label, this.width, this.height);
  final String label;
  final int width;
  final int height;
  double get ratio => width / height;
}

class Project {
  final List<VideoClip> clips = [];
  final List<TextOverlay> texts = [];
  MusicTrack? music;
  AspectRatioPreset aspect = AspectRatioPreset.portrait;

  Duration get totalDuration =>
      clips.fold(Duration.zero, (sum, c) => sum + c.outputDuration);

  /// Istante di inizio della clip [index] sulla timeline finale.
  Duration startOf(int index) {
    var t = Duration.zero;
    for (var i = 0; i < index && i < clips.length; i++) {
      t += clips[i].outputDuration;
    }
    return t;
  }
}
