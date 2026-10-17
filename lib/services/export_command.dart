import 'dart:math' as math;

import '../models/project.dart';

/// Immagine PNG già renderizzata di un [VideoOverlay] (testo, sticker o
/// sottotitolo), con le sue dimensioni in pixel del video finale.
class RenderedOverlay {
  const RenderedOverlay(this.overlay, this.path, this.width, this.height);
  final VideoOverlay overlay;
  final String path;
  final int width;
  final int height;
}

/// Costruisce gli argomenti FFmpeg per esportare un [Project].
///
/// È codice Dart puro (niente plugin), così si testa con `flutter test` e
/// la CI esegue il comando generato con un FFmpeg vero.
///
/// Ordine dei livelli: clip principali (con transizioni) → sovrapposizioni
/// video/foto (PiP) → testi, sticker e sottotitoli. Audio: clip + musica +
/// voci fuori campo / suoni + audio delle sovrapposizioni.
class ExportCommand {
  ExportCommand({
    required this.project,
    required this.outputPath,
    this.overlays = const [],
    this.pipMasks = const {},
    this.fps = 30,
    this.preset = 'veryfast',
  });

  final Project project;
  final String outputPath;
  final List<RenderedOverlay> overlays;

  /// Indice della sovrapposizione → PNG in scala di grigi della maschera
  /// (bianco = visibile), già alla dimensione in pixel del livello.
  final Map<int, String> pipMasks;
  final int fps;
  final String preset;

  static const _audioFormat =
      'aformat=sample_fmts=fltp:sample_rates=44100:channel_layouts=stereo';

  List<String> build() {
    final p = project;
    if (p.clips.isEmpty) throw StateError('Il progetto non contiene clip.');
    final w = p.aspect.width, h = p.aspect.height;
    final args = <String>['-y'];
    final f = <String>[];
    var input = 0;

    // ── 1) Ogni clip → [v{i}] e [a{i}] ──────────────────────────────
    for (var i = 0; i < p.clips.length; i++) {
      final c = p.clips[i];
      final dur = c.outputDuration.inMicroseconds / 1e6;
      final frames = (dur * fps).round().clamp(1, 1 << 30);
      final speed = c.speed.clamp(0.5, 2.0).toStringAsFixed(3);

      final chain = StringBuffer();
      if (c.isImage) {
        args.addAll(['-loop', '1', '-framerate', '$fps', '-t', _n(c.outputDuration), '-i', c.path]);
        chain.write('[${input++}:v]fps=$fps,setpts=PTS-STARTPTS');
      } else {
        args.addAll(['-i', c.path]);
        final vi = input++;
        chain.write('[$vi:v]trim=start=${_n(c.trimStart)}:end=${_n(c.trimEnd)},'
            'setpts=(PTS-STARTPTS)/$speed,fps=$fps');
        if (c.hasAudio) {
          final fx = [
            if (c.denoise) 'afftdn=nf=-25',
            if (c.voiceFx.ffmpeg != null) c.voiceFx.ffmpeg!,
          ];
          f.add('[$vi:a]atrim=start=${_n(c.trimStart)}:end=${_n(c.trimEnd)},asetpts=PTS-STARTPTS,'
              'atempo=$speed,volume=${c.volume.toStringAsFixed(2)}'
              '${fx.isEmpty ? '' : ',${fx.join(',')}'},$_audioFormat[a$i]');
        }
      }
      if (c.isImage || !c.hasAudio) {
        final d = _n(c.outputDuration);
        args.addAll(['-f', 'lavfi', '-t', d, '-i', 'anullsrc=r=44100:cl=stereo']);
        f.add('[${input++}:a]atrim=duration=$d,asetpts=PTS-STARTPTS,$_audioFormat[a$i]');
      }

      final turn = _transpose(c.quarterTurns);
      if (turn != null) chain.write(',$turn');
      switch (p.background) {
        case CanvasBackground.blur:
          chain
            ..write(',split[bs$i][fs$i];')
            ..write('[bs$i]scale=$w:$h:force_original_aspect_ratio=increase,'
                'crop=$w:$h,boxblur=30:3[bg$i];')
            ..write('[fs$i]scale=$w:$h:force_original_aspect_ratio=decrease[fg$i];')
            ..write('[bg$i][fg$i]overlay=(W-w)/2:(H-h)/2');
        case CanvasBackground.black:
        case CanvasBackground.white:
          final color = p.background == CanvasBackground.white ? 'white' : 'black';
          chain.write(',scale=$w:$h:force_original_aspect_ratio=decrease,'
              'pad=$w:$h:(ow-iw)/2:(oh-ih)/2:color=$color');
      }
      chain.write(',setsar=1,format=yuv420p');
      if (c.filter.ffmpeg != null) chain.write(',${c.filter.ffmpeg}');
      final fx = _effect(c.effect, w, h, frames, fps);
      if (fx != null) chain.write(',$fx');
      chain.write(',settb=AVTB[v$i]');
      f.add(chain.toString());
    }

    // ── 2) Unione a coppie: xfade/acrossfade o concat ───────────────
    var vCur = 'v0', aCur = 'a0';
    var length = p.clips.first.outputDuration;
    for (var i = 1; i < p.clips.length; i++) {
      final tr = p.transitionAfter(i - 1);
      final type = p.clips[i - 1].transition;
      final vNext = 'vj$i', aNext = 'aj$i';
      if (tr > Duration.zero && type.xfade != null) {
        final offset = length - tr;
        f.add('[$vCur][v$i]xfade=transition=${type.xfade}:'
            'duration=${_n(tr)}:offset=${_n(offset)}[$vNext]');
        f.add('[$aCur][a$i]acrossfade=d=${_n(tr)}[$aNext]');
        length = length + p.clips[i].outputDuration - tr;
      } else {
        f.add('[$vCur][v$i]concat=n=2:v=1:a=0[$vNext]');
        f.add('[$aCur][a$i]concat=n=2:v=0:a=1[$aNext]');
        length += p.clips[i].outputDuration;
      }
      vCur = vNext;
      aCur = aNext;
    }

    final total = p.totalDuration;
    final totalS = total.inMicroseconds / 1e6;
    final extraAudio = <String>[];

    // ── 3) Sovrapposizioni video/foto (PiP) ────────────────────────
    for (var k = 0; k < p.pips.length; k++) {
      final l = p.pips[k];
      if (l.start >= total || l.duration <= Duration.zero) continue;
      final s = l.start.inMicroseconds / 1e6;
      final d = math.max(0.05, math.min(l.duration.inMicroseconds / 1e6, totalS - s));
      final (pw, ph) = l.pixelSize(w);
      if (l.isImage) {
        args.addAll(['-loop', '1', '-framerate', '$fps', '-t', d.toStringAsFixed(3), '-i', l.path]);
      } else {
        args.addAll(['-ss', _n(l.trimStart), '-t', d.toStringAsFixed(3), '-i', l.path]);
      }
      final li = input++;
      final chain = StringBuffer('[$li:v]fps=$fps,setpts=PTS-STARTPTS,scale=$pw:$ph,setsar=1,format=rgba');
      final mask = pipMasks[k];
      if (mask != null) {
        args.addAll(['-loop', '1', '-framerate', '$fps', '-t', d.toStringAsFixed(3), '-i', mask]);
        final mi = input++;
        chain.write('[pv$k];[$mi:v]format=gray,scale=$pw:$ph[pm$k];[pv$k][pm$k]alphamerge');
      }
      // Il chroma key va dopo la maschera: alphamerge sovrascrive l'alfa.
      if (l.chroma != null) {
        final rgb = (l.chroma!.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
        chain.write(',colorkey=0x$rgb:${l.chromaSimilarity.toStringAsFixed(3)}:0.08');
      }
      if (l.opacity < 0.999) chain.write(',colorchannelmixer=aa=${l.opacity.toStringAsFixed(3)}');
      chain.write(',setpts=PTS+${s.toStringAsFixed(3)}/TB[p$k]');
      f.add(chain.toString());

      final prog = 'clip((t-${s.toStringAsFixed(3)})/${d.toStringAsFixed(3)},0,1)';
      final x = _lerp(l.cx, l.toCx, prog), y = _lerp(l.cy, l.toCy, prog);
      final next = 'vp$k';
      f.add("[$vCur][p$k]overlay=x='($x)*W-w/2':y='($y)*H-h/2':eval=frame:eof_action=pass:"
          "enable='between(t,${s.toStringAsFixed(3)},${(s + d).toStringAsFixed(3)})'[$next]");
      vCur = next;

      if (l.hasAudio && !l.isImage && l.volume > 0.001) {
        final ms = (s * 1000).round();
        f.add('[$li:a]asetpts=PTS-STARTPTS,volume=${l.volume.toStringAsFixed(2)},'
            '$_audioFormat,adelay=$ms|$ms[pa$k]');
        extraAudio.add('pa$k');
      }
    }

    // ── 4) Testi, sticker e sottotitoli ────────────────────────────
    for (var k = 0; k < overlays.length; k++) {
      final r = overlays[k];
      final o = r.overlay;
      if (o.start >= total) continue;
      final end = o.end > total ? total : o.end;
      final s = o.start.inMicroseconds / 1e6, e = end.inMicroseconds / 1e6;
      args.addAll([
        '-loop', '1', '-framerate', '$fps', //
        '-t', (e - s).toStringAsFixed(3),
        '-i', r.path,
      ]);
      final oi = input++;
      final alpha = opacityExpr(o, 'T', 0, e - s);
      final ov = StringBuffer('[$oi:v]format=rgba');
      if (alpha != '1') {
        ov.write(",geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':"
            "a='alpha(X,Y)*clip($alpha,0,1)'");
      }
      ov.write(',setpts=PTS+${s.toStringAsFixed(3)}/TB[o$k]');
      f.add(ov.toString());

      final origEnd = o.end.inMicroseconds / 1e6;
      final prog = 'clip((t-${s.toStringAsFixed(3)})/${(origEnd - s).clamp(0.001, 1e9).toStringAsFixed(3)},0,1)';
      final bx = _lerp(o.cx, o.toCx, prog), by = _lerp(o.cy, o.toCy, prog);
      final (dx, dy) = offsetExpr(o, 't', s, e);
      final next = 'vo$k';
      f.add("[$vCur][o$k]overlay="
          "x='($bx)*W-w/2${dx == '0' ? '' : '+($dx)*W'}':"
          "y='($by)*H-h/2${dy == '0' ? '' : '+($dy)*H'}':"
          "eval=frame:eof_action=pass:"
          "enable='between(t,${s.toStringAsFixed(3)},${e.toStringAsFixed(3)})'[$next]");
      vCur = next;
    }

    // ── 5) Musica, voci fuori campo, effetti sonori ────────────────
    final music = p.music;
    if (music != null) {
      args.addAll([
        '-stream_loop', '-1', // ripete il brano se è più corto del video
        '-ss', _n(music.offset),
        '-i', music.path,
      ]);
      final mi = input++;
      final fade = music.fadeOut && totalS > 3
          ? ',afade=t=out:st=${(totalS - 2).toStringAsFixed(3)}:d=2'
          : '';
      f.add('[$mi:a]atrim=duration=${_n(total)},asetpts=PTS-STARTPTS,'
          'volume=${music.volume.toStringAsFixed(2)}$fade,$_audioFormat[mus]');
      extraAudio.insert(0, 'mus');
    }
    for (var k = 0; k < p.audios.length; k++) {
      final a = p.audios[k];
      if (a.start >= total) continue;
      args.addAll(['-i', a.path]);
      final ai = input++;
      final ms = (a.start.inMicroseconds / 1000).round();
      final fx = [
        if (a.denoise) 'afftdn=nf=-25',
        if (a.fx.ffmpeg != null) a.fx.ffmpeg!,
      ];
      f.add('[$ai:a]atrim=duration=${_n(a.duration)},asetpts=PTS-STARTPTS'
          '${fx.isEmpty ? '' : ',${fx.join(',')}'},'
          'volume=${a.volume.toStringAsFixed(2)},$_audioFormat,adelay=$ms|$ms[au$k]');
      extraAudio.add('au$k');
    }
    if (extraAudio.isNotEmpty) {
      final ins = ['[$aCur]', for (final a in extraAudio) '[$a]'].join();
      f.add('${ins}amix=inputs=${extraAudio.length + 1}:duration=first:'
          'dropout_transition=0:normalize=0[amix]');
      aCur = 'amix';
    }

    args.addAll([
      '-filter_complex', f.join(';'),
      '-map', '[$vCur]',
      '-map', '[$aCur]',
      '-c:v', 'libx264',
      '-preset', preset,
      '-crf', '21',
      '-pix_fmt', 'yuv420p',
      '-c:a', 'aac',
      '-b:a', '192k',
      '-movflags', '+faststart',
      '-t', _n(total),
      outputPath,
    ]);
    return args;
  }

  static String? _transpose(int quarterTurns) {
    switch (quarterTurns % 4) {
      case 1:
        return 'transpose=1';
      case 2:
        return 'hflip,vflip';
      case 3:
        return 'transpose=2';
      default:
        return null;
    }
  }

  /// Interpolazione lineare tra due valori (keyframe), come espressione.
  static String _lerp(double from, double? to, String prog) {
    if (to == null || (to - from).abs() < 1e-6) return _d(from);
    return '${_d(from)}+(${_d(to - from)})*$prog';
  }

  /// Filtro FFmpeg per un effetto, o null.
  static String? _effect(ClipEffect e, int w, int h, int frames, int fps) {
    switch (e) {
      case ClipEffect.none:
        return null;
      case ClipEffect.zoomIn:
        return "zoompan=z='1+0.18*on/$frames':d=1:"
            "x='iw/2-iw/zoom/2':y='ih/2-ih/zoom/2':s=${w}x$h:fps=$fps";
      case ClipEffect.zoomOut:
        return "zoompan=z='1.18-0.18*on/$frames':d=1:"
            "x='iw/2-iw/zoom/2':y='ih/2-ih/zoom/2':s=${w}x$h:fps=$fps";
      case ClipEffect.shake:
        return "crop=w=iw*0.94:h=ih*0.94:"
            "x='(iw-ow)/2+sin(t*40)*14':y='(ih-oh)/2+cos(t*33)*14',scale=$w:$h";
      case ClipEffect.glitch:
        return 'rgbashift=rh=-10:bh=10:gv=4,noise=alls=14:allf=t';
      case ClipEffect.vhs:
        return 'noise=alls=18:allf=t,eq=saturation=0.75,'
            'curves=preset=vintage,rgbashift=rh=4';
      case ClipEffect.vignette:
        return 'vignette=PI/4';
      case ClipEffect.mirror:
        return 'hflip';
      case ClipEffect.blur:
        return 'boxblur=12:2';
      case ClipEffect.flash:
        return 'fade=t=in:st=0:d=0.35:color=white';
    }
  }

  /// Espressione FFmpeg dell'opacità (stessa formula di [VideoOverlay.animAt]).
  static String opacityExpr(VideoOverlay o, String t, double s, double e) {
    const d = VideoOverlay.animDuration;
    final pin = 'clip(($t-${_d(s)})/$d,0,1)';
    final pout = 'clip(($t-${_d(e - d)})/$d,0,1)';
    final parts = <String>[];
    switch (o.animIn) {
      case AnimIn.none:
        break;
      case AnimIn.fade:
      case AnimIn.slideUp:
      case AnimIn.slideLeft:
      case AnimIn.slideDown:
        parts.add(pin);
      case AnimIn.bounce:
        parts.add('clip(($t-${_d(s)})/0.1,0,1)');
    }
    switch (o.animOut) {
      case AnimOut.none:
        break;
      case AnimOut.fade:
      case AnimOut.slideDown:
      case AnimOut.slideRight:
        parts.add('(1-$pout)');
    }
    return parts.isEmpty ? '1' : parts.join('*');
  }

  /// Espressioni FFmpeg degli spostamenti (frazioni di W e H).
  static (String, String) offsetExpr(VideoOverlay o, String t, double s, double e) {
    const d = VideoOverlay.animDuration;
    final pin = 'clip(($t-${_d(s)})/$d,0,1)';
    final pout = 'clip(($t-${_d(e - d)})/$d,0,1)';
    final dx = <String>[], dy = <String>[];
    switch (o.animIn) {
      case AnimIn.none:
      case AnimIn.fade:
        break;
      case AnimIn.slideUp:
        dy.add('(1-$pin)*0.12');
      case AnimIn.slideDown:
        dy.add('-(1-$pin)*0.12');
      case AnimIn.slideLeft:
        dx.add('-(1-$pin)*0.3');
      case AnimIn.bounce:
        final k = 'clip($t-${_d(s)},0,0.8)';
        dy.add('-abs(sin($k*12))*0.04*(1-$k/0.8)');
    }
    switch (o.animOut) {
      case AnimOut.none:
      case AnimOut.fade:
        break;
      case AnimOut.slideDown:
        dy.add('$pout*0.12');
      case AnimOut.slideRight:
        dx.add('$pout*0.3');
    }
    return (
      dx.isEmpty ? '0' : dx.join('+'),
      dy.isEmpty ? '0' : dy.join('+'),
    );
  }

  /// Secondi con 3 decimali.
  static String _n(Duration d) =>
      (d.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(3);

  static String _d(double v) => v.toStringAsFixed(4);
}
