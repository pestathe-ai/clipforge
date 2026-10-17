import 'package:clipforge/models/project.dart';
import 'package:clipforge/services/export_command.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
      ),
      VideoClip(
        path: '/v/b.mp4',
        sourceDuration: const Duration(seconds: 4),
        hasAudio: false,
      ),
    ]);
    return p;
  }

  test('durata totale tiene conto di taglio e velocità', () {
    expect(sample().totalDuration, const Duration(seconds: 6));
  });

  test('genera silenzio per le clip senza audio e concatena', () {
    final args = ExportCommand(
      project: sample(),
      outputPath: '/out.mp4',
      fontPath: '/f.ttf',
      textFilePaths: const [],
    ).build();
    final graph = args[args.indexOf('-filter_complex') + 1];

    expect(args, contains('anullsrc=r=44100:cl=stereo'));
    expect(graph, contains('[0:v]trim=start=1.000:end=5.000'));
    expect(graph, contains('atempo=2.000'));
    expect(graph, contains('hue=s=0'));
    expect(graph, contains('[2:a]atrim=duration=4.000'));
    expect(graph, contains('[v0][a0][v1][a1]concat=n=2:v=1:a=1[vcat][acat]'));
    expect(args.last, '/out.mp4');
  });

  test('aggiunge testi e musica con i label giusti', () {
    final p = sample()
      ..texts.add(TextOverlay(
        text: 'Ciao',
        start: const Duration(milliseconds: 500),
        end: const Duration(seconds: 4),
      ))
      ..music = MusicTrack(path: '/m.mp3', duration: const Duration(seconds: 3));
    final args = ExportCommand(
      project: p,
      outputPath: '/out.mp4',
      fontPath: "/it's/f.ttf",
      textFilePaths: const ['/t0.txt'],
    ).build();
    final graph = args[args.indexOf('-filter_complex') + 1];

    expect(graph, contains("fontfile='/it'\\''s/f.ttf'"));
    expect(graph, contains("enable='between(t,0.500,4.000)'[vt0]"));
    expect(graph, contains('[3:a]atrim=duration=6.000'));
    expect(graph, contains('amix=inputs=2'));
    expect(args.sublist(args.indexOf('-map')), containsAllInOrder(
        ['-map', '[vt0]', '-map', '[amix]']));
  });

  test('progetto vuoto lancia un errore', () {
    expect(
      () => ExportCommand(
        project: Project(),
        outputPath: '/o.mp4',
        fontPath: '/f.ttf',
        textFilePaths: const [],
      ).build(),
      throwsStateError,
    );
  });
}
