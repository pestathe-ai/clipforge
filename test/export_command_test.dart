import 'dart:convert';
import 'dart:io';

import 'package:clipforge/models/project.dart';
import 'package:clipforge/services/export_command.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';

Project sample() {
  final p = Project();
  p.clips.addAll([
    VideoClip(
      path: '/v/a.mp4',
      sourceDuration: const Duration(seconds: 6),
      hasAudio: true,
      trimStart: const Duration(seconds: 1),
      trimEnd: const Duration(seconds: 5),
      speed: 2,
      filter: VideoFilter.mono,
      transition: TransitionType.fade,
      transitionDuration: const Duration(milliseconds: 500),
    ),
    VideoClip(
      path: '/v/b.mp4',
      sourceDuration: const Duration(seconds: 4),
      hasAudio: false,
      effect: ClipEffect.zoomIn,
    ),
  ]);
  return p;
}

void main() {
  test('durata totale tiene conto di taglio, velocità e transizioni', () {
    // 2 s + 4 s − 0,5 s di sovrapposizione.
    expect(sample().totalDuration, const Duration(milliseconds: 5500));
    expect(sample().startOf(1), const Duration(milliseconds: 1500));
  });

  test('transizione con xfade/acrossfade e silenzio per clip senza audio', () {
    final args = ExportCommand(project: sample(), outputPath: '/out.mp4').build();
    final graph = args[args.indexOf('-filter_complex') + 1];
    expect(args, contains('anullsrc=r=44100:cl=stereo'));
    expect(graph, contains('[0:v]trim=start=1.000:end=5.000'));
    expect(graph, contains('xfade=transition=fade:duration=0.500:offset=1.500'));
    expect(graph, contains('acrossfade=d=0.500'));
    expect(graph, contains('zoompan='));
    expect(graph, contains('hue=s=0'));
    expect(args.last, '/out.mp4');
  });

  test('overlay animati con espressioni coerenti con l\'anteprima', () {
    final p = sample();
    final o = VideoOverlay(
      kind: OverlayKind.text,
      text: 'Ciao',
      start: const Duration(seconds: 1),
      end: const Duration(seconds: 3),
      animIn: AnimIn.slideUp,
      animOut: AnimOut.fade,
    );
    p.overlays.add(o);
    final args = ExportCommand(
      project: p,
      outputPath: '/out.mp4',
      overlays: [RenderedOverlay(o, '/o.png', 200, 80)],
    ).build();
    final graph = args[args.indexOf('-filter_complex') + 1];
    expect(graph, contains("geq=r='r(X,Y)'"));
    expect(graph, contains('setpts=PTS+1.000/TB'));
    expect(graph, contains("enable='between(t,1.000,3.000)'"));

    // A metà dell'entrata (t = 1,2 s) anteprima ed export devono coincidere.
    final a = o.animAt(1.2);
    expect(a.opacity, closeTo(0.5, 1e-9));
    expect(a.dy, closeTo(0.06, 1e-9));
  });

  test('progetto: salvataggio e ripristino JSON', () {
    final p = sample()
      ..overlays.add(VideoOverlay(
          kind: OverlayKind.sticker, text: '🔥', start: Duration.zero, end: const Duration(seconds: 1)));
    final back = Project.decode(p.encode());
    expect(back.encode(), p.encode());
  });

  test('keyframe: movimento lineare e JSON delle novità v0.3', () {
    final l = PipLayer(
      path: '/x.mp4', isImage: false, sourceDuration: const Duration(seconds: 4),
      width: 640, height: 360, hasAudio: false, start: const Duration(seconds: 1),
      trimEnd: const Duration(seconds: 2), cx: 0.2, toCx: 0.6);
    expect(l.centerAt(const Duration(seconds: 2)).dx, closeTo(0.4, 1e-9));
    expect(l.pixelSize(1080), (540, 304));
    final p = sample()..pips.add(l)..audios.add(AudioItem(path: '/v.m4a', start: Duration.zero, duration: const Duration(seconds: 1)));
    expect(Project.decode(p.encode()).encode(), p.encode());
    final args = ExportCommand(project: p, outputPath: '/o.mp4', pipMasks: {0: '/m.png'}).build();
    final graph = args[args.indexOf('-filter_complex') + 1];
    expect(graph, contains('alphamerge'));
    expect(graph, contains('adelay=0|0'));
  });

  test('curve di velocità: durata e conversioni coerenti', () {
    final c = VideoClip(
      path: '/x.mp4',
      sourceDuration: const Duration(seconds: 10),
      hasAudio: true,
      trimStart: const Duration(seconds: 1),
      trimEnd: const Duration(seconds: 6),
      speedCurve: SpeedCurve.jump, // 0.5, 3, 0.5 su tratti di 5/3 s
    );
    const third = 5 / 3;
    final expected = third / 0.5 + third / 3 + third / 0.5;
    expect(c.outputDuration.inMicroseconds / 1e6, closeTo(expected, 1e-3));
    for (final ms in [0, 500, 2000, 4000, 6000, 7000]) {
      final local = Duration(milliseconds: ms);
      final back = c.localAt(c.sourceAt(local));
      expect((back - local).inMicroseconds.abs(), lessThan(2000));
    }
    expect(c.speedAt(Duration.zero), 0.5);
    final graph = (ExportCommand(project: Project()..clips.add(c), outputPath: '/o.mp4').build());
    final g = graph[graph.indexOf('-filter_complex') + 1];
    expect(g, contains('split=3'));
    expect(g, contains('asplit=3'));
    expect(g, contains('atempo=0.7071,atempo=0.7071'));
  });

  test('progetto vuoto lancia un errore', () {
    expect(() => ExportCommand(project: Project(), outputPath: '/o.mp4').build(), throwsStateError);
  });

  // Usato dalla CI: genera un comando con TUTTI gli effetti e le transizioni
  // su video veri, poi la CI lo esegue con FFmpeg.
  test('genera comando completo per la verifica in CI', () {
    final dir = Platform.environment['CLIPFORGE_MEDIA'];
    if (dir == null) return;
    for (final bg in CanvasBackground.values) {
      final p = Project()
        ..background = bg
        ..resolution = bg == CanvasBackground.blur ? 720 : 1080
        ..fps = bg == CanvasBackground.white ? 24 : 30;
      final effects = ClipEffect.values;
      final transitions = TransitionType.values;
      final n = transitions.length;
      for (var i = 0; i < n; i++) {
        final withAudio = i.isEven;
        if (i == 3) {
          p.clips.add(VideoClip.image('$dir/photo.jpg', duration: const Duration(seconds: 2))
            ..transition = transitions[i]
            ..quarterTurns = 1);
          continue;
        }
        p.clips.add(VideoClip(
          path: '$dir/${withAudio ? 'a' : 'b'}.mp4',
          sourceDuration: const Duration(seconds: 4),
          hasAudio: withAudio,
          trimStart: const Duration(milliseconds: 500),
          trimEnd: const Duration(milliseconds: 2500),
          speed: i % 3 == 0 ? 1.5 : 1.0,
          effect: effects[i % effects.length],
          filter: VideoFilter.values[i % VideoFilter.values.length],
          transition: transitions[i],
          transitionDuration: const Duration(milliseconds: 400),
          quarterTurns: i % 4,
          width: withAudio ? 1280 : 720,
          height: withAudio ? 720 : 1280,
          speedCurve: SpeedCurve.values[i % SpeedCurve.values.length],
          adjust: i % 3 == 1 ? const ColorAdjust(brightness: 0.1, contrast: 1.2, saturation: 1.3, warmth: 0.5, sharpen: 0.5) : const ColorAdjust(),
          stabilize: i == 5,
          cropZoom: i % 4 == 2 ? 1.5 : 1.0,
          cropX: 0.3,
          cropY: -0.2,
          fadeIn: withAudio ? const Duration(milliseconds: 300) : Duration.zero,
          fadeOut: withAudio ? const Duration(milliseconds: 300) : Duration.zero,
          bgMask: withAudio && i % 4 == 0 ? '$dir/maskvid.mp4' : null,
          denoise: i == 2,
          voiceFx: withAudio ? AudioFx.values[i % AudioFx.values.length] : AudioFx.none,
        ));
      }
      // Sovrapposizioni: video con green screen + maschera + movimento, foto.
      p.pips.addAll([
        PipLayer(
          path: '$dir/green.mp4',
          isImage: false,
          sourceDuration: const Duration(seconds: 4),
          width: 640,
          height: 360,
          hasAudio: true,
          start: const Duration(seconds: 1),
          trimStart: const Duration(milliseconds: 500),
          trimEnd: const Duration(milliseconds: 3500),
          mask: MaskShape.circle,
          bgMask: '$dir/maskvid.mp4',
          toScale: 0.7,
          rotation: 0.2,
          toRotation: -0.4,
          chroma: const Color(0xFF00FF00),
          opacity: 0.8,
          toCx: 0.8,
          toCy: 0.6,
        ),
        PipLayer(
          path: '$dir/photo.jpg',
          isImage: true,
          sourceDuration: const Duration(minutes: 10),
          width: 800,
          height: 600,
          hasAudio: false,
          start: const Duration(seconds: 5),
          trimEnd: const Duration(seconds: 2),
          scale: 0.3,
          track: [0, 0.3, 0.3, 0.5, 0.35, 0.32, 1.0, 0.45, 0.4, 1.5, 0.5, 0.42],
        ),
      ]);
      p.audios.addAll([
        AudioItem(path: '$dir/voice.m4a', start: const Duration(milliseconds: 1500),
            duration: const Duration(seconds: 2), fx: AudioFx.echo, denoise: true),
        AudioItem(path: '$dir/a.mp4', start: const Duration(seconds: 3), duration: const Duration(seconds: 2),
            sourceStart: const Duration(seconds: 1), fadeIn: const Duration(milliseconds: 500),
            fadeOut: const Duration(milliseconds: 500)),
        AudioItem(path: '$dir/voice.m4a', start: const Duration(seconds: 6),
            duration: const Duration(seconds: 2), isVoice: false, fx: AudioFx.chipmunk),
      ]);
      p.music = MusicTrack(path: '$dir/m.mp3', duration: const Duration(seconds: 3));
      final overlays = <RenderedOverlay>[];
      var k = 0;
      for (final ai in AnimIn.values) {
        final o = VideoOverlay(
          kind: OverlayKind.text,
          text: 'x',
          start: Duration(milliseconds: 500 + k * 1500),
          end: Duration(milliseconds: 2500 + k * 1500),
          animIn: ai,
          animOut: AnimOut.values[k % AnimOut.values.length],
          cx: 0.3 + 0.1 * (k % 4),
          toScale: k == 1 ? 1.8 : null,
          toRotation: k == 2 ? 1.0 : null,
          track: k == 3 ? [0, 0.4, 0.4, 0.5, 0.45, 0.5, 1.0, 0.5, 0.55] : null,
        );
        p.overlays.add(o);
        overlays.add(RenderedOverlay(o, '$dir/ov.png', 300, 100));
        k++;
      }
      final args = ExportCommand(
        project: p,
        outputPath: '$dir/out_${bg.name}.mp4',
        overlays: overlays,
        pipMasks: {0: '$dir/mask.png'},
        preset: 'ultrafast',
      ).build();
      File('$dir/args_${bg.name}.json').writeAsStringSync(jsonEncode(args));
      File('$dir/expected_${bg.name}.txt')
          .writeAsStringSync((p.totalDuration.inMicroseconds / 1e6).toStringAsFixed(3));
    }
  });
}
