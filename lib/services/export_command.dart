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
/// Per ogni clip: taglio → velocità → adattamento al formato (con sfondo
/// nero/bianco/sfocato) → filtro colore → effetto. Poi le clip vengono unite
/// a coppie con `xfade`/`acrossfade` (transizione) o `concat`, si
/// sovrappongono testi/sticker animati e si mixa la musica.
class ExportCommand {
  ExportCommand({
    required this.project,
    required this.outputPath,
    this.overlays = const [],
    this.fps = 30,
    this.preset = 'veryfast',
  });

  final Project project;
  final String outputPath;
  final List<RenderedOverlay> overlays;
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
      args.addAll(['-i', c.path]);
      final vi = input++;
      final start = _n(c.trimStart), end = _n(c.trimEnd);
      final speed = c.speed.clamp(0.5, 2.0).toStringAsFixed(3);
      final dur = c.outputDuration.inMicroseconds / 1e6;
      final frames = (dur * fps).round().clamp(1, 1 << 30);

      final chain = StringBuffer(
          '[$vi:v]trim=start=$start:end=$end,setpts=(PTS-STARTPTS)/$speed,fps=$fps');
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

      if (c.hasAudio) {
        f.add('[$vi:a]atrim=start=$start:end=$end,asetpts=PTS-STARTPTS,'
            'atempo=$speed,volume=${c.volume.toStringAsFixed(2)},$_audioFormat[a$i]');
      } else {
        final d = _n(c.outputDuration);
        args.addAll(['-f', 'lavfi', '-t', d, '-i', 'anullsrc=r=44100:cl=stereo']);
        final ni = input++;
        f.add('[$ni:a]atrim=duration=$d,asetpts=PTS-STARTPTS,$_audioFormat[a$i]');
      }
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

    // ── 3) Testi, sticker e sottotitoli ────────────────────────────
    final total = p.totalDuration;
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

      final (dx, dy) = offsetExpr(o, 't', s, e);
      final next = 'vo$k';
      f.add("[$vCur][o$k]overlay="
          "x='${_d(o.cx)}*W-w/2${dx == '0' ? '' : '+($dx)*W'}':"
          "y='${_d(o.cy)}*H-h/2${dy == '0' ? '' : '+($dy)*H'}':"
          "eval=frame:eof_action=pass:"
          "enable='between(t,${s.toStringAsFixed(3)},${e.toStringAsFixed(3)})'[$next]");
      vCur = next;
    }

    // ── 4) Musica ───────────────────────────────────────────────────
    final music = p.music;
    if (music != null) {
      args.addAll([
        '-stream_loop', '-1', // ripete il brano se è più corto del video
        '-ss', _n(music.offset),
        '-i', music.path,
      ]);
      final mi = input++;
      final totalS = total.inMicroseconds / 1e6;
      final fade = music.fadeOut && totalS > 3
          ? ',afade=t=out:st=${(totalS - 2).toStringAsFixed(3)}:d=2'
          : '';
      f.add('[$mi:a]atrim=duration=${_n(total)},asetpts=PTS-STARTPTS,'
          'volume=${music.volume.toStringAsFixed(2)}$fade,$_audioFormat[mus]');
      f.add('[$aCur][mus]amix=inputs=2:duration=first:'
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
      outputPath,
    ]);
    return args;
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
