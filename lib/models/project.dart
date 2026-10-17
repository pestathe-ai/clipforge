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

  /// Durata della clip nel video finale, dopo taglio e velocità.
  Duration get outputDuration => Duration(
        microseconds: ((trimEnd - trimStart).inMicroseconds / speed).round(),
      );

  /// Converte un istante locale (0 = inizio clip nel video finale)
  /// nella posizione corrispondente del file sorgente.
  Duration sourceAt(Duration local) =>
      trimStart + Duration(microseconds: (local.inMicroseconds * speed).round());

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
      );
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
  });

  final String path;
  Duration start;
  final Duration duration;
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
      };

  factory AudioItem.fromJson(Map<String, dynamic> j) => AudioItem(
        path: j['path'] as String,
        start: Duration(microseconds: j['start'] as int),
        duration: Duration(microseconds: j['duration'] as int),
        volume: (j['volume'] as num).toDouble(),
        fx: _enum(AudioFx.values, j['fx'], AudioFx.none),
        isVoice: (j['isVoice'] as bool?) ?? true,
        denoise: (j['denoise'] as bool?) ?? false,
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

  Duration get duration => trimEnd - trimStart;
  Duration get end => start + duration;
  bool visibleAt(Duration t) => t >= start && t < end;

  /// Posizione all'istante [t] (con keyframe).
  Offset centerAt(Duration t) {
    final k = duration.inMicroseconds <= 0
        ? 0.0
        : ((t - start).inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);
    return Offset(cx + ((toCx ?? cx) - cx) * k, cy + ((toCy ?? cy) - cy) * k);
  }

  /// Dimensioni in pixel nel video finale (pari, come vuole x264).
  (int, int) pixelSize(int frameWidth) {
    final w = ((frameWidth * scale) / 2).round() * 2;
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

  /// Centro senza animazioni di entrata/uscita, con il keyframe applicato.
  Offset centerAt(Duration t) {
    final len = (end - start).inMicroseconds;
    final k = len <= 0 ? 0.0 : ((t - start).inMicroseconds / len).clamp(0.0, 1.0);
    return Offset(cx + ((toCx ?? cx) - cx) * k, cy + ((toCy ?? cy) - cy) * k);
  }
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
        'version': 3,
        'aspect': aspect.name,
        'background': background.name,
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
