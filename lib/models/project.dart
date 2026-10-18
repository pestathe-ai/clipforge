import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

// ─────────────────────────── Filtri colore ───────────────────────────

/// Filtri colore. Ognuno ha un filtro FFmpeg per l'export e una matrice
/// colore per l'anteprima in-app.
enum VideoFilter {
  none('Nessuno', null),
  mono('B/N', 'hue=s=0'),
  sepia(
    'Seppia',
    'colorchannelmixer=.393:.769:.189:0:.349:.686:.168:0:.272:.534:.131',
  ),
  vivid('Vivace', 'eq=saturation=1.6'),
  contrast('Contrasto', 'eq=contrast=1.35:brightness=0.02'),
  cool('Freddo', 'colorbalance=bs=0.25:bm=0.15:rs=-0.1'),
  warm('Caldo', 'colorbalance=rs=0.2:rm=0.12:bs=-0.15'),
  fade('Sbiadito', 'eq=contrast=0.85:saturation=0.75:brightness=0.06'),
  noir('Noir', 'hue=s=0,eq=contrast=1.5:brightness=-0.05');

  const VideoFilter(this.label, this.ffmpeg);
  final String label;
  final String? ffmpeg;

  /// Matrice 4x5 per [ColorFilter.matrix], usata solo per l'anteprima.
  List<double>? get previewMatrix {
    List<double> sat(double s, {double gain = 1, double off = 0}) {
      final r = 0.2126 * (1 - s), g = 0.7152 * (1 - s), b = 0.0722 * (1 - s);
      return [
        (r + s) * gain, g * gain, b * gain, 0, off, //
        r * gain, (g + s) * gain, b * gain, 0, off,
        r * gain, g * gain, (b + s) * gain, 0, off,
        0, 0, 0, 1, 0,
      ];
    }

    switch (this) {
      case VideoFilter.none:
        return null;
      case VideoFilter.mono:
        return sat(0);
      case VideoFilter.noir:
        return sat(0, gain: 1.5, off: -76);
      case VideoFilter.sepia:
        return const [
          0.393, 0.769, 0.189, 0, 0, //
          0.349, 0.686, 0.168, 0, 0,
          0.272, 0.534, 0.131, 0, 0,
          0, 0, 0, 1, 0,
        ];
      case VideoFilter.vivid:
        return sat(1.6);
      case VideoFilter.contrast:
        return sat(1, gain: 1.35, off: -40);
      case VideoFilter.fade:
        return sat(0.75, gain: 0.85, off: 34);
      case VideoFilter.cool:
        return const [
          0.9, 0, 0, 0, 0, //
          0, 1.0, 0, 0, 10,
          0, 0, 1.2, 0, 25,
          0, 0, 0, 1, 0,
        ];
      case VideoFilter.warm:
        return const [
          1.15, 0, 0, 0, 15, //
          0, 1.05, 0, 0, 5,
          0, 0, 0.85, 0, 0,
          0, 0, 0, 1, 0,
        ];
    }
  }
}

// ─────────────────────────── Effetti ───────────────────────────

/// Effetti video applicati a una clip.
enum ClipEffect {
  none('Nessuno', Icons.block_rounded),
  zoomIn('Zoom lento', Icons.zoom_in_rounded),
  zoomOut('Zoom indietro', Icons.zoom_out_rounded),
  shake('Tremolio', Icons.vibration_rounded),
  glitch('Glitch', Icons.broken_image_rounded),
  vhs('VHS', Icons.videocam_rounded),
  vignette('Vignetta', Icons.vignette_rounded),
  mirror('Specchio', Icons.flip_rounded),
  blur('Sfocato', Icons.blur_on_rounded),
  flash('Flash iniziale', Icons.flash_on_rounded);

  const ClipEffect(this.label, this.icon);
  final String label;
  final IconData icon;
}

// ─────────────────────────── Transizioni ───────────────────────────

/// Transizioni tra una clip e la successiva (nomi `xfade` di FFmpeg).
enum TransitionType {
  none('Nessuna', null, Icons.block_rounded),
  fade('Dissolvenza', 'fade', Icons.gradient_rounded),
  fadeBlack('Nero', 'fadeblack', Icons.brightness_2_rounded),
  fadeWhite('Bianco', 'fadewhite', Icons.brightness_7_rounded),
  slideLeft('Scorri ←', 'slideleft', Icons.arrow_back_rounded),
  slideUp('Scorri ↑', 'slideup', Icons.arrow_upward_rounded),
  wipe('Tendina', 'wipeleft', Icons.view_week_rounded),
  circle('Cerchio', 'circleopen', Icons.circle_outlined),
  zoom('Zoom', 'zoomin', Icons.center_focus_strong_rounded),
  pixel('Pixel', 'pixelize', Icons.grid_on_rounded),
  blur('Sfocatura', 'hblur', Icons.blur_linear_rounded),
  squeeze('Schiaccia', 'squeezeh', Icons.compress_rounded);

  const TransitionType(this.label, this.xfade, this.icon);
  final String label;
  final String? xfade;
  final IconData icon;
}

// ─────────────────────────── Clip ───────────────────────────

class VideoClip {
  VideoClip({
    required this.path,
    required this.sourceDuration,
    required this.hasAudio,
    Duration? trimStart,
    Duration? trimEnd,
    this.speed = 1.0,
    this.filter = VideoFilter.none,
    this.effect = ClipEffect.none,
    this.volume = 1.0,
    this.transition = TransitionType.none,
    this.transitionDuration = const Duration(milliseconds: 600),
    this.isImage = false,
    this.quarterTurns = 0,
    this.denoise = false,
    this.voiceFx = AudioFx.none,
    this.reversed = false,
    this.originalPath,
    this.width = 0,
    this.height = 0,
    this.speedCurve = SpeedCurve.none,
    this.adjust = const ColorAdjust(),
    this.stabilize = false,
    this.cropZoom = 1.0,
    this.cropX = 0.0,
    this.cropY = 0.0,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
    this.bgMask,
  })  : trimStart = trimStart ?? Duration.zero,
        trimEnd = trimEnd ?? sourceDuration;

  /// Una foto: dura quanto si vuole (taglio = durata).
  factory VideoClip.image(String path, {Duration duration = const Duration(seconds: 3)}) =>
      VideoClip(
        path: path,
        sourceDuration: imageMaxDuration,
        hasAudio: false,
        trimEnd: duration,
        isImage: true,
        effect: ClipEffect.zoomIn,
      );

  static const imageMaxDuration = Duration(seconds: 60);

  /// File usato (per una clip al contrario è la copia invertita).
  String path;
  final Duration sourceDuration;
  final bool hasAudio;
  Duration trimStart;
  Duration trimEnd;

  /// Velocità di riproduzione, limitata a 0.5–2.0 (range di `atempo`).
  double speed;
  VideoFilter filter;
  ClipEffect effect;

  /// Volume dell'audio originale della clip (0–2).
  double volume;

  /// Transizione verso la clip *successiva*.
  TransitionType transition;
  Duration transitionDuration;

  bool isImage;

  /// Rotazione in quarti di giro in senso orario (0–3).
  int quarterTurns;

  /// Riduzione del rumore di fondo sull'audio.
  bool denoise;
  AudioFx voiceFx;

  /// Riproduzione al contrario: [path] punta a una copia invertita,
  /// [originalPath] al file originale.
  bool reversed;
  String? originalPath;

  /// Dimensioni del file sorgente (già ruotate secondo i metadati), 0 se ignote.
  int width;
  int height;

  SpeedCurve speedCurve;
  ColorAdjust adjust;
  bool stabilize;

  /// Ritaglio: ingrandimento (1–3) e spostamento (-1…1) dentro l'inquadratura.
  double cropZoom;
  double cropX;
  double cropY;

  /// Dissolvenze dell'audio della clip.
  Duration fadeIn;
  Duration fadeOut;

  /// Video maschera (bianco = persona) per la rimozione dello sfondo, o null.
  String? bgMask;

  bool get hasCrop => cropZoom > 1.001;

  /// Tratti a velocità costante: (inizio sorgente, fine sorgente, velocità).
  List<(Duration, Duration, double)> get segments {
    final base = speed.clamp(0.25, 4.0);
    final curve = speedCurve.points;
    if (isImage || curve == null) return [(trimStart, trimEnd, base)];
    final len = (trimEnd - trimStart).inMicroseconds;
    final n = curve.length;
    return [
      for (var k = 0; k < n; k++)
        (
          trimStart + Duration(microseconds: len * k ~/ n),
          trimStart + Duration(microseconds: len * (k + 1) ~/ n),
          (curve[k] * base).clamp(0.25, 4.0),
        ),
    ];
  }

  /// Durata della clip nel video finale, dopo taglio e velocità.
  Duration get outputDuration {
    var us = 0.0;
    for (final (s, e, v) in segments) {
      us += (e - s).inMicroseconds / v;
    }
    return Duration(microseconds: us.round());
  }

  /// Converte un istante locale (0 = inizio clip nel video finale)
  /// nella posizione corrispondente del file sorgente.
  Duration sourceAt(Duration local) {
    var rest = local.inMicroseconds.toDouble();
    final segs = segments;
    for (final (s, e, v) in segs) {
      final out = (e - s).inMicroseconds / v;
      if (rest <= out) return s + Duration(microseconds: (rest * v).round());
      rest -= out;
    }
    return segs.last.$2;
  }

  /// Inverso di [sourceAt].
  Duration localAt(Duration source) {
    var acc = 0.0;
    for (final (s, e, v) in segments) {
      if (source <= e) {
        final into = (source - s).inMicroseconds.clamp(0, (e - s).inMicroseconds);
        return Duration(microseconds: (acc + into / v).round());
      }
      acc += (e - s).inMicroseconds / v;
    }
    return Duration(microseconds: acc.round());
  }

  /// Velocità effettiva all'istante locale [local].
  double speedAt(Duration local) {
    var rest = local.inMicroseconds.toDouble();
    final segs = segments;
    for (final (s, e, v) in segs) {
      final out = (e - s).inMicroseconds / v;
      if (rest < out) return v;
      rest -= out;
    }
    return segs.last.$3;
  }

  VideoClip copy() => VideoClip.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'path': path,
        'sourceDuration': sourceDuration.inMicroseconds,
        'hasAudio': hasAudio,
        'trimStart': trimStart.inMicroseconds,
        'trimEnd': trimEnd.inMicroseconds,
        'speed': speed,
        'filter': filter.name,
        'effect': effect.name,
        'volume': volume,
        'transition': transition.name,
        'transitionDuration': transitionDuration.inMicroseconds,
        'isImage': isImage,
        'quarterTurns': quarterTurns,
        'denoise': denoise,
        'voiceFx': voiceFx.name,
        'reversed': reversed,
        'originalPath': originalPath,
        'width': width,
        'height': height,
        'speedCurve': speedCurve.name,
        'adjust': adjust.toJson(),
        'stabilize': stabilize,
        'cropZoom': cropZoom,
        'cropX': cropX,
        'cropY': cropY,
        'fadeIn': fadeIn.inMicroseconds,
        'fadeOut': fadeOut.inMicroseconds,
        'bgMask': bgMask,
      };

  factory VideoClip.fromJson(Map<String, dynamic> j) => VideoClip(
        path: j['path'] as String,
        sourceDuration: Duration(microseconds: j['sourceDuration'] as int),
        hasAudio: j['hasAudio'] as bool,
        trimStart: Duration(microseconds: j['trimStart'] as int),
        trimEnd: Duration(microseconds: j['trimEnd'] as int),
        speed: (j['speed'] as num).toDouble(),
        filter: _enum(VideoFilter.values, j['filter'], VideoFilter.none),
        effect: _enum(ClipEffect.values, j['effect'], ClipEffect.none),
        volume: (j['volume'] as num).toDouble(),
        transition:
            _enum(TransitionType.values, j['transition'], TransitionType.none),
        transitionDuration:
            Duration(microseconds: (j['transitionDuration'] as int?) ?? 600000),
        isImage: (j['isImage'] as bool?) ?? false,
        quarterTurns: (j['quarterTurns'] as int?) ?? 0,
        denoise: (j['denoise'] as bool?) ?? false,
        voiceFx: _enum(AudioFx.values, j['voiceFx'], AudioFx.none),
        reversed: (j['reversed'] as bool?) ?? false,
        originalPath: j['originalPath'] as String?,
        width: (j['width'] as int?) ?? 0,
        height: (j['height'] as int?) ?? 0,
        speedCurve: _enum(SpeedCurve.values, j['speedCurve'], SpeedCurve.none),
        adjust: j['adjust'] == null
            ? const ColorAdjust()
            : ColorAdjust.fromJson(j['adjust'] as Map<String, dynamic>),
        stabilize: (j['stabilize'] as bool?) ?? false,
        cropZoom: (j['cropZoom'] as num?)?.toDouble() ?? 1.0,
        cropX: (j['cropX'] as num?)?.toDouble() ?? 0.0,
        cropY: (j['cropY'] as num?)?.toDouble() ?? 0.0,
        fadeIn: Duration(microseconds: (j['fadeIn'] as int?) ?? 0),
        fadeOut: Duration(microseconds: (j['fadeOut'] as int?) ?? 0),
        bgMask: j['bgMask'] as String?,
      );
}

// ─────────────────────────── Curve di velocità ───────────────────────────

/// Curve di velocità in stile CapCut: la clip è divisa in tratti uguali
/// (del file sorgente), ciascuno con il proprio moltiplicatore.
enum SpeedCurve {
  none('Nessuna', null),
  montage('Montaggio', [1.0, 2.5, 0.5, 2.5, 1.0]),
  hero('Eroe', [2.0, 2.0, 0.3, 0.3, 2.0, 2.0]),
  bullet('Proiettile', [1.5, 0.3, 0.3, 0.3, 1.5]),
  jump('Salto', [0.5, 3.0, 0.5]),
  flash('Lampo', [3.0, 3.0, 0.4, 3.0, 3.0]),
  speedUp('Accelera', [0.5, 0.8, 1.2, 1.8, 2.5]),
  slowDown('Rallenta', [2.5, 1.8, 1.2, 0.8, 0.5]);

  const SpeedCurve(this.label, this.points);
  final String label;
  final List<double>? points;
}

// ─────────────────────────── Regolazioni colore ───────────────────────────

class ColorAdjust {
  const ColorAdjust({
    this.brightness = 0,
    this.contrast = 1,
    this.saturation = 1,
    this.warmth = 0,
    this.sharpen = 0,
  });

  /// -0.3…0.3
  final double brightness;

  /// 0.5…1.5
  final double contrast;

  /// 0…2
  final double saturation;

  /// -1 (freddo) … 1 (caldo)
  final double warmth;

  /// 0…1
  final double sharpen;

  bool get isNeutral =>
      brightness.abs() < 0.005 &&
      (contrast - 1).abs() < 0.005 &&
      (saturation - 1).abs() < 0.005 &&
      warmth.abs() < 0.005 &&
      sharpen < 0.005;

  ColorAdjust copyWith({double? brightness, double? contrast, double? saturation, double? warmth, double? sharpen}) =>
      ColorAdjust(
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        warmth: warmth ?? this.warmth,
        sharpen: sharpen ?? this.sharpen,
      );

  /// Filtro FFmpeg equivalente, o null se neutro.
  String? get ffmpeg {
    if (isNeutral) return null;
    final parts = <String>[
      'eq=brightness=${brightness.toStringAsFixed(3)}:contrast=${contrast.toStringAsFixed(3)}'
          ':saturation=${saturation.toStringAsFixed(3)}',
      if (warmth.abs() >= 0.005)
        'colorbalance=rm=${(warmth * 0.15).toStringAsFixed(3)}:bm=${(-warmth * 0.15).toStringAsFixed(3)}',
      if (sharpen >= 0.005) 'unsharp=5:5:${(sharpen * 1.5).toStringAsFixed(3)}',
    ];
    return parts.join(',');
  }

  /// Matrice colore per l'anteprima (approssimata).
  List<double> get matrix {
    final s = saturation, c = contrast, b = brightness * 255;
    final r = 0.2126 * (1 - s), g = 0.7152 * (1 - s), bl = 0.0722 * (1 - s);
    final off = (1 - c) * 128 + b;
    final wr = 1 + warmth * 0.12, wb = 1 - warmth * 0.12;
    return [
      (r + s) * c * wr, g * c * wr, bl * c * wr, 0, off, //
      r * c, (g + s) * c, bl * c, 0, off,
      r * c * wb, g * c * wb, (bl + s) * c * wb, 0, off,
      0, 0, 0, 1, 0,
    ];
  }

  Map<String, dynamic> toJson() => {
        'brightness': brightness,
        'contrast': contrast,
        'saturation': saturation,
        'warmth': warmth,
        'sharpen': sharpen,
      };

  factory ColorAdjust.fromJson(Map<String, dynamic> j) => ColorAdjust(
        brightness: (j['brightness'] as num).toDouble(),
        contrast: (j['contrast'] as num).toDouble(),
        saturation: (j['saturation'] as num).toDouble(),
        warmth: (j['warmth'] as num).toDouble(),
        sharpen: (j['sharpen'] as num).toDouble(),
      );
}

// ─────────────────────────── Tracciamento ───────────────────────────

/// Spostamento dovuto al tracciamento all'istante [tRel] (secondi
/// dall'inizio dell'elemento), rispetto al primo punto del percorso.
/// [track] è una lista piatta di terne (t, x, y).
Offset? trackDelta(List<double>? track, double tRel) {
  if (track == null || track.length < 6) return null;
  final x0 = track[1], y0 = track[2];
  final n = track.length ~/ 3;
  if (tRel <= track[0]) return Offset.zero;
  for (var i = 1; i < n; i++) {
    final t1 = track[i * 3];
    if (tRel <= t1) {
      final t0 = track[(i - 1) * 3];
      final k = t1 - t0 <= 0 ? 1.0 : (tRel - t0) / (t1 - t0);
      final x = track[(i - 1) * 3 + 1] + (track[i * 3 + 1] - track[(i - 1) * 3 + 1]) * k;
      final y = track[(i - 1) * 3 + 2] + (track[i * 3 + 2] - track[(i - 1) * 3 + 2]) * k;
      return Offset(x - x0, y - y0);
    }
  }
  return Offset(track[(n - 1) * 3 + 1] - x0, track[(n - 1) * 3 + 2] - y0);
}

// ─────────────────────────── Effetti audio ───────────────────────────

enum AudioFx {
  none('Nessuno', null),
  chipmunk('Scoiattolo', 'asetrate=44100*1.35,aresample=44100,atempo=1/1.35'),
  deep('Voce profonda', 'asetrate=44100*0.78,aresample=44100,atempo=1/0.78'),
  echo('Eco', 'aecho=0.8:0.85:120|240:0.35|0.2'),
  radio('Radio', 'highpass=f=500,lowpass=f=3000,acompressor'),
  megaphone('Megafono', 'highpass=f=800,lowpass=f=2500,volume=1.6,acrusher=bits=10:mode=log:aa=1'),
  hall('Sala grande', 'aecho=0.8:0.7:60|90|140:0.4|0.3|0.2');

  const AudioFx(this.label, this.ffmpeg);
  final String label;
  final String? ffmpeg;
}

/// Voce fuori campo o effetto sonoro posizionato sulla timeline.
class AudioItem {
  AudioItem({
    required this.path,
    required this.start,
    required this.duration,
    this.volume = 1.0,
    this.fx = AudioFx.none,
    this.isVoice = true,
    this.denoise = false,
    this.sourceStart = Duration.zero,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
  });

  final String path;
  Duration start;
  final Duration duration;

  /// Da che punto del file partire (per l'audio estratto da una clip).
  final Duration sourceStart;
  Duration fadeIn;
  Duration fadeOut;
  double volume;
  AudioFx fx;
  bool isVoice;
  bool denoise;

  Duration get end => start + duration;

  Map<String, dynamic> toJson() => {
        'path': path,
        'start': start.inMicroseconds,
        'duration': duration.inMicroseconds,
        'volume': volume,
        'fx': fx.name,
        'isVoice': isVoice,
        'denoise': denoise,
        'sourceStart': sourceStart.inMicroseconds,
        'fadeIn': fadeIn.inMicroseconds,
        'fadeOut': fadeOut.inMicroseconds,
      };

  factory AudioItem.fromJson(Map<String, dynamic> j) => AudioItem(
        path: j['path'] as String,
        start: Duration(microseconds: j['start'] as int),
        duration: Duration(microseconds: j['duration'] as int),
        volume: (j['volume'] as num).toDouble(),
        fx: _enum(AudioFx.values, j['fx'], AudioFx.none),
        isVoice: (j['isVoice'] as bool?) ?? true,
        denoise: (j['denoise'] as bool?) ?? false,
        sourceStart: Duration(microseconds: (j['sourceStart'] as int?) ?? 0),
        fadeIn: Duration(microseconds: (j['fadeIn'] as int?) ?? 0),
        fadeOut: Duration(microseconds: (j['fadeOut'] as int?) ?? 0),
      );
}

// ─────────────────────────── Sovrapposizioni (PiP) ───────────────────────────

enum MaskShape {
  none('Nessuna', Icons.crop_square_rounded),
  circle('Cerchio', Icons.circle_outlined),
  rounded('Arrotondata', Icons.rounded_corner_rounded),
  heart('Cuore', Icons.favorite_border_rounded),
  star('Stella', Icons.star_border_rounded),
  diamond('Rombo', Icons.diamond_outlined);

  const MaskShape(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Video o foto sovrapposti al video principale (picture-in-picture),
/// con maschera, chroma key (green screen), opacità e movimento.
class PipLayer {
  PipLayer({
    required this.path,
    required this.isImage,
    required this.sourceDuration,
    required this.width,
    required this.height,
    required this.hasAudio,
    required this.start,
    Duration? trimStart,
    Duration? trimEnd,
    this.cx = 0.5,
    this.cy = 0.35,
    this.scale = 0.5,
    this.opacity = 1.0,
    this.mask = MaskShape.none,
    this.chroma,
    this.chromaSimilarity = 0.3,
    this.toCx,
    this.toCy,
    this.volume = 1.0,
    this.rotation = 0,
    this.toScale,
    this.toRotation,
    this.track,
    this.bgMask,
  })  : trimStart = trimStart ?? Duration.zero,
        trimEnd = trimEnd ?? sourceDuration;

  final String path;
  final bool isImage;
  final Duration sourceDuration;

  /// Dimensioni del file sorgente in pixel.
  final int width;
  final int height;
  final bool hasAudio;

  /// Inizio sulla timeline finale.
  Duration start;
  Duration trimStart;
  Duration trimEnd;

  /// Centro (0–1) e larghezza come frazione della larghezza del video.
  double cx;
  double cy;
  double scale;
  double opacity;
  MaskShape mask;

  /// Colore da rendere trasparente (green screen), o null.
  Color? chroma;
  double chromaSimilarity;

  /// Keyframe finale della posizione: se impostato, il livello si sposta
  /// da (cx, cy) a (toCx, toCy) durante la sua durata.
  double? toCx;
  double? toCy;
  double volume;

  /// Rotazione in radianti, e keyframe finali di scala e rotazione.
  double rotation;
  double? toScale;
  double? toRotation;

  /// Percorso del tracciamento (terne t, x, y), o null.
  List<double>? track;

  /// Video maschera per la rimozione dello sfondo, o null.
  String? bgMask;

  Duration get duration => trimEnd - trimStart;
  Duration get end => start + duration;
  bool visibleAt(Duration t) => t >= start && t < end;

  double _progress(Duration t) => duration.inMicroseconds <= 0
      ? 0.0
      : ((t - start).inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);

  /// Posizione all'istante [t] (con keyframe o tracciamento).
  Offset centerAt(Duration t) {
    final d = trackDelta(track, (t - start).inMicroseconds / 1e6);
    if (d != null) return Offset(cx, cy) + d;
    final k = _progress(t);
    return Offset(cx + ((toCx ?? cx) - cx) * k, cy + ((toCy ?? cy) - cy) * k);
  }

  double scaleAt(Duration t) => scale + ((toScale ?? scale) - scale) * _progress(t);
  double rotationAt(Duration t) => rotation + ((toRotation ?? rotation) - rotation) * _progress(t);
  double get maxScale => math.max(scale, toScale ?? scale);

  /// Dimensioni in pixel nel video finale (pari, come vuole x264).
  (int, int) pixelSize(int frameWidth, [double? atScale]) {
    final w = ((frameWidth * (atScale ?? scale)) / 2).round() * 2;
    final h = ((w * height / width) / 2).round() * 2;
    return (math.max(2, w), math.max(2, h));
  }

  PipLayer copy() => PipLayer.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'path': path,
        'isImage': isImage,
        'sourceDuration': sourceDuration.inMicroseconds,
        'width': width,
        'height': height,
        'hasAudio': hasAudio,
        'start': start.inMicroseconds,
        'trimStart': trimStart.inMicroseconds,
        'trimEnd': trimEnd.inMicroseconds,
        'cx': cx,
        'cy': cy,
        'scale': scale,
        'opacity': opacity,
        'mask': mask.name,
        'chroma': chroma?.toARGB32(),
        'chromaSimilarity': chromaSimilarity,
        'toCx': toCx,
        'toCy': toCy,
        'volume': volume,
        'rotation': rotation,
        'toScale': toScale,
        'toRotation': toRotation,
        'track': track,
        'bgMask': bgMask,
      };

  factory PipLayer.fromJson(Map<String, dynamic> j) => PipLayer(
        path: j['path'] as String,
        isImage: j['isImage'] as bool,
        sourceDuration: Duration(microseconds: j['sourceDuration'] as int),
        width: j['width'] as int,
        height: j['height'] as int,
        hasAudio: j['hasAudio'] as bool,
        start: Duration(microseconds: j['start'] as int),
        trimStart: Duration(microseconds: j['trimStart'] as int),
        trimEnd: Duration(microseconds: j['trimEnd'] as int),
        cx: (j['cx'] as num).toDouble(),
        cy: (j['cy'] as num).toDouble(),
        scale: (j['scale'] as num).toDouble(),
        opacity: (j['opacity'] as num).toDouble(),
        mask: _enum(MaskShape.values, j['mask'], MaskShape.none),
        chroma: j['chroma'] == null ? null : Color(j['chroma'] as int),
        chromaSimilarity: (j['chromaSimilarity'] as num?)?.toDouble() ?? 0.3,
        toCx: (j['toCx'] as num?)?.toDouble(),
        toCy: (j['toCy'] as num?)?.toDouble(),
        volume: (j['volume'] as num?)?.toDouble() ?? 1.0,
        rotation: (j['rotation'] as num?)?.toDouble() ?? 0,
        toScale: (j['toScale'] as num?)?.toDouble(),
        toRotation: (j['toRotation'] as num?)?.toDouble(),
        track: (j['track'] as List?)?.map((e) => (e as num).toDouble()).toList(),
        bgMask: j['bgMask'] as String?,
      );
}

// ─────────────────────────── VideoOverlay (testi e sticker) ───────────────────────────

enum OverlayKind { text, sticker, subtitle }

enum AnimIn {
  none('Nessuna'),
  fade('Dissolvenza'),
  slideUp('Dal basso'),
  slideLeft('Da sinistra'),
  bounce('Rimbalzo'),
  slideDown('Dall\'alto');

  const AnimIn(this.label);
  final String label;
}

enum AnimOut {
  none('Nessuna'),
  fade('Dissolvenza'),
  slideDown('Verso il basso'),
  slideRight('Verso destra');

  const AnimOut(this.label);
  final String label;
}

/// Testo, sticker (emoji) o sottotitolo sovrapposto al video.
///
/// La posizione è normalizzata (0–1) sul fotogramma finale, la dimensione è
/// in pixel del video esportato. Lo stesso disegno viene usato per
/// l'anteprima e per l'export, così quello che vedi è quello che ottieni.
class VideoOverlay {
  VideoOverlay({
    required this.kind,
    required this.text,
    required this.start,
    required this.end,
    this.color = Colors.white,
    this.fontSize = 72,
    this.box = false,
    this.boxColor = const Color(0x99000000),
    this.outline = true,
    this.cx = 0.5,
    this.cy = 0.75,
    this.rotation = 0,
    this.animIn = AnimIn.fade,
    this.animOut = AnimOut.fade,
    this.toCx,
    this.toCy,
    this.toScale,
    this.toRotation,
    this.track,
    this.tag,
  });

  OverlayKind kind;
  String text;
  Duration start;
  Duration end;
  Color color;
  double fontSize;
  bool box;
  Color boxColor;
  bool outline;
  double cx;
  double cy;

  /// Rotazione in radianti.
  double rotation;

  /// Keyframe finale della posizione (movimento lineare durante la durata).
  double? toCx;
  double? toCy;

  /// Keyframe finali: scala (moltiplicatore) e rotazione (radianti).
  double? toScale;
  double? toRotation;

  /// Percorso del tracciamento (terne t, x, y), o null.
  List<double>? track;

  /// Ruolo speciale: 'meme-top' / 'meme-bottom' per i testi del meme.
  String? tag;
  bool get isMeme => tag != null && tag!.startsWith('meme');

  double _progress(Duration t) {
    final len = (end - start).inMicroseconds;
    return len <= 0 ? 0.0 : ((t - start).inMicroseconds / len).clamp(0.0, 1.0);
  }

  /// Centro senza animazioni di entrata/uscita, con keyframe o tracciamento.
  Offset centerAt(Duration t) {
    final d = trackDelta(track, (t - start).inMicroseconds / 1e6);
    if (d != null) return Offset(cx, cy) + d;
    final k = _progress(t);
    return Offset(cx + ((toCx ?? cx) - cx) * k, cy + ((toCy ?? cy) - cy) * k);
  }

  /// Moltiplicatore di scala e rotazione aggiuntiva all'istante [t].
  double scaleAt(Duration t) => 1 + ((toScale ?? 1) - 1) * _progress(t);
  double extraRotationAt(Duration t) => toRotation == null ? 0 : (toRotation! - rotation) * _progress(t);
  AnimIn animIn;
  AnimOut animOut;

  static const animDuration = 0.4; // secondi

  bool visibleAt(Duration t) => t >= start && t < end;

  /// Stato dell'animazione all'istante [t] (secondi), usato sia
  /// dall'anteprima che dall'export (che replica la stessa formula in FFmpeg).
  ({double opacity, double dx, double dy}) animAt(double t) {
    final s = start.inMicroseconds / 1e6, e = end.inMicroseconds / 1e6;
    const d = animDuration;
    var opacity = 1.0, dx = 0.0, dy = 0.0;
    final pin = ((t - s) / d).clamp(0.0, 1.0); // 0→1 in entrata
    final pout = ((t - (e - d)) / d).clamp(0.0, 1.0); // 0→1 in uscita
    switch (animIn) {
      case AnimIn.none:
        break;
      case AnimIn.fade:
        opacity *= pin;
      case AnimIn.slideUp:
        opacity *= pin;
        dy += (1 - pin) * 0.12;
      case AnimIn.slideLeft:
        opacity *= pin;
        dx -= (1 - pin) * 0.3;
      case AnimIn.bounce:
        final k = (t - s).clamp(0.0, 0.8);
        dy -= (math.sin(k * 12)).abs() * 0.04 * (1 - k / 0.8);
        opacity *= ((t - s) / 0.1).clamp(0.0, 1.0);
      case AnimIn.slideDown:
        opacity *= pin;
        dy -= (1 - pin) * 0.12;
    }
    switch (animOut) {
      case AnimOut.none:
        break;
      case AnimOut.fade:
        opacity *= 1 - pout;
      case AnimOut.slideDown:
        opacity *= 1 - pout;
        dy += pout * 0.12;
      case AnimOut.slideRight:
        opacity *= 1 - pout;
        dx += pout * 0.3;
    }
    return (opacity: opacity, dx: dx, dy: dy);
  }

  VideoOverlay copy() => VideoOverlay.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'text': text,
        'start': start.inMicroseconds,
        'end': end.inMicroseconds,
        'color': color.toARGB32(),
        'fontSize': fontSize,
        'box': box,
        'boxColor': boxColor.toARGB32(),
        'outline': outline,
        'cx': cx,
        'cy': cy,
        'rotation': rotation,
        'animIn': animIn.name,
        'animOut': animOut.name,
        'toCx': toCx,
        'toCy': toCy,
        'toScale': toScale,
        'toRotation': toRotation,
        'track': track,
        'tag': tag,
      };

  factory VideoOverlay.fromJson(Map<String, dynamic> j) => VideoOverlay(
        kind: _enum(OverlayKind.values, j['kind'], OverlayKind.text),
        text: j['text'] as String,
        start: Duration(microseconds: j['start'] as int),
        end: Duration(microseconds: j['end'] as int),
        color: Color(j['color'] as int),
        fontSize: (j['fontSize'] as num).toDouble(),
        box: j['box'] as bool,
        boxColor: Color(j['boxColor'] as int),
        outline: j['outline'] as bool,
        cx: (j['cx'] as num).toDouble(),
        cy: (j['cy'] as num).toDouble(),
        rotation: (j['rotation'] as num?)?.toDouble() ?? 0,
        animIn: _enum(AnimIn.values, j['animIn'], AnimIn.none),
        animOut: _enum(AnimOut.values, j['animOut'], AnimOut.none),
        toCx: (j['toCx'] as num?)?.toDouble(),
        toCy: (j['toCy'] as num?)?.toDouble(),
        toScale: (j['toScale'] as num?)?.toDouble(),
        toRotation: (j['toRotation'] as num?)?.toDouble(),
        track: (j['track'] as List?)?.map((e) => (e as num).toDouble()).toList(),
        tag: j['tag'] as String?,
      );
}

// ─────────────────────────── Musica ───────────────────────────

class MusicTrack {
  MusicTrack({
    required this.path,
    required this.duration,
    this.volume = 0.6,
    this.offset = Duration.zero,
    this.fadeOut = true,
  });

  final String path;
  final Duration duration;
  double volume;

  /// Da che punto del brano partire.
  Duration offset;

  /// Sfuma la musica negli ultimi 2 secondi.
  bool fadeOut;

  Map<String, dynamic> toJson() => {
        'path': path,
        'duration': duration.inMicroseconds,
        'volume': volume,
        'offset': offset.inMicroseconds,
        'fadeOut': fadeOut,
      };

  factory MusicTrack.fromJson(Map<String, dynamic> j) => MusicTrack(
        path: j['path'] as String,
        duration: Duration(microseconds: j['duration'] as int),
        volume: (j['volume'] as num).toDouble(),
        offset: Duration(microseconds: j['offset'] as int),
        fadeOut: (j['fadeOut'] as bool?) ?? true,
      );
}

// ─────────────────────────── Formato e progetto ───────────────────────────

enum AspectRatioPreset {
  portrait('9:16', 1080, 1920),
  square('1:1', 1080, 1080),
  landscape('16:9', 1920, 1080),
  classic('4:5', 1080, 1350);

  const AspectRatioPreset(this.label, this.width, this.height);
  final String label;
  final int width;
  final int height;
  double get ratio => width / height;
}

/// Cosa mettere ai lati quando la clip non riempie il formato.
enum CanvasBackground {
  black('Nero'),
  blur('Sfocato'),
  white('Bianco');

  const CanvasBackground(this.label);
  final String label;
}

class Project {
  Project({this.aspect = AspectRatioPreset.portrait});

  final List<VideoClip> clips = [];
  final List<VideoOverlay> overlays = [];
  final List<AudioItem> audios = [];
  final List<PipLayer> pips = [];
  MusicTrack? music;
  AspectRatioPreset aspect;
  CanvasBackground background = CanvasBackground.blur;

  /// Risoluzione (lato corto, in pixel) e fotogrammi al secondo dell'export.
  int resolution = 1080;
  int fps = 30;

  /// Modalità meme: fasce sopra e sotto (frazioni dell'altezza) con il testo.
  bool meme = false;
  double memeTop = 0.18;
  double memeBottom = 0.18;
  bool memeWhite = false;

  /// Zona occupata dal video (in pixel del formato base), pari per x264.
  (int top, int height) videoBand(int h) {
    if (!meme) return (0, h);
    final top = ((h * memeTop) / 2).round() * 2;
    final bottom = ((h * memeBottom) / 2).round() * 2;
    return (top, (h - top - bottom).clamp(2, h));
  }

  /// Durata effettiva della transizione tra la clip [i] e la [i+1]
  /// (0 se nessuna; limitata per non superare metà delle due clip).
  Duration transitionAfter(int i) {
    if (i < 0 || i >= clips.length - 1) return Duration.zero;
    final c = clips[i];
    if (c.transition == TransitionType.none) return Duration.zero;
    final limit = Duration(
      microseconds: (math.min(c.outputDuration.inMicroseconds,
                  clips[i + 1].outputDuration.inMicroseconds) *
              0.45)
          .round(),
    );
    return c.transitionDuration < limit ? c.transitionDuration : limit;
  }

  /// Istante di inizio della clip [index] sulla timeline finale
  /// (le transizioni sovrappongono le clip).
  Duration startOf(int index) {
    var t = Duration.zero;
    for (var i = 0; i < index && i < clips.length; i++) {
      t += clips[i].outputDuration - transitionAfter(i);
    }
    return t;
  }

  Duration get totalDuration {
    if (clips.isEmpty) return Duration.zero;
    return startOf(clips.length - 1) + clips.last.outputDuration;
  }

  /// Indice della clip visibile all'istante [t].
  int clipIndexAt(Duration t) {
    for (var i = 0; i < clips.length; i++) {
      if (t < startOf(i) + clips[i].outputDuration - transitionAfter(i) ~/ 2) {
        return i;
      }
    }
    return clips.length - 1;
  }

  /// Tiene testi, sticker, audio e sovrapposizioni dentro la durata del video.
  void clampOverlays() {
    final total = totalDuration;
    // I testi del meme restano per tutta la durata.
    for (final o in overlays) {
      if (o.isMeme) {
        o.start = Duration.zero;
        o.end = total;
      }
    }
    overlays.removeWhere((o) => o.start >= total);
    for (final o in overlays) {
      if (o.end > total) o.end = total;
    }
    audios.removeWhere((a) => a.start >= total);
    pips.removeWhere((l) => l.start >= total);
    for (final l in pips) {
      if (l.end > total) l.trimEnd = l.trimStart + (total - l.start);
    }
  }

  Project copy() => Project.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'version': 4,
        'aspect': aspect.name,
        'background': background.name,
        'resolution': resolution,
        'fps': fps,
        'meme': meme,
        'memeTop': memeTop,
        'memeBottom': memeBottom,
        'memeWhite': memeWhite,
        'clips': [for (final c in clips) c.toJson()],
        'overlays': [for (final o in overlays) o.toJson()],
        'audios': [for (final a in audios) a.toJson()],
        'pips': [for (final l in pips) l.toJson()],
        'music': music?.toJson(),
      };

  String encode() => jsonEncode(toJson());

  factory Project.fromJson(Map<String, dynamic> j) {
    final p = Project(
      aspect: _enum(AspectRatioPreset.values, j['aspect'],
          AspectRatioPreset.portrait),
    )..background =
        _enum(CanvasBackground.values, j['background'], CanvasBackground.blur);
    p.clips.addAll([
      for (final c in (j['clips'] as List)) VideoClip.fromJson(c as Map<String, dynamic>)
    ]);
    p.overlays.addAll([
      for (final o in (j['overlays'] as List)) VideoOverlay.fromJson(o as Map<String, dynamic>)
    ]);
    p.resolution = (j['resolution'] as int?) ?? 1080;
    p.fps = (j['fps'] as int?) ?? 30;
    p.meme = (j['meme'] as bool?) ?? false;
    p.memeTop = (j['memeTop'] as num?)?.toDouble() ?? 0.18;
    p.memeBottom = (j['memeBottom'] as num?)?.toDouble() ?? 0.18;
    p.memeWhite = (j['memeWhite'] as bool?) ?? false;
    p.audios.addAll([
      for (final a in (j['audios'] as List? ?? const [])) AudioItem.fromJson(a as Map<String, dynamic>)
    ]);
    p.pips.addAll([
      for (final l in (j['pips'] as List? ?? const [])) PipLayer.fromJson(l as Map<String, dynamic>)
    ]);
    final m = j['music'];
    if (m != null) p.music = MusicTrack.fromJson(m as Map<String, dynamic>);
    return p;
  }

  factory Project.decode(String s) =>
      Project.fromJson(jsonDecode(s) as Map<String, dynamic>);
}

T _enum<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}
