import '../models/project.dart';

/// Costruisce gli argomenti FFmpeg per esportare un [Project].
///
/// È codice Dart puro (niente plugin), così si può testare con `flutter test`.
/// Il grafo dei filtri fa, per ogni clip: taglio → velocità → adattamento al
/// formato scelto → filtro colore; poi concatena tutto, sovrappone i testi e
/// mixa la musica.
class ExportCommand {
  ExportCommand({
    required this.project,
    required this.outputPath,
    required this.fontPath,
    required this.textFilePaths,
    this.fps = 30,
  }) : assert(textFilePaths.length == project.texts.length);

  final Project project;
  final String outputPath;

  /// Percorso locale di un file .ttf (drawtext richiede un file vero).
  final String fontPath;

  /// Un file di testo per ogni [TextOverlay], nello stesso ordine:
  /// `textfile=` evita tutti i problemi di escape di `text=`.
  final List<String> textFilePaths;
  final int fps;

  static const _audioFormat =
      'aformat=sample_fmts=fltp:sample_rates=44100:channel_layouts=stereo';

  List<String> build() {
    if (project.clips.isEmpty) {
      throw StateError('Il progetto non contiene clip.');
    }
    final w = project.aspect.width;
    final h = project.aspect.height;
    final args = <String>['-y'];
    final filters = <String>[];
    var inputIndex = 0;

    // 1) Clip video (+ silenzio generato per le clip senza audio).
    final concatInputs = StringBuffer();
    for (var i = 0; i < project.clips.length; i++) {
      final c = project.clips[i];
      args.addAll(['-i', c.path]);
      final vIdx = inputIndex++;

      final start = _s(c.trimStart);
      final end = _s(c.trimEnd);
      final speed = c.speed.clamp(0.5, 2.0);

      final v = StringBuffer()
        ..write('[$vIdx:v]trim=start=$start:end=$end,')
        ..write('setpts=(PTS-STARTPTS)/${speed.toStringAsFixed(3)},')
        ..write('scale=$w:$h:force_original_aspect_ratio=decrease,')
        ..write('pad=$w:$h:(ow-iw)/2:(oh-ih)/2:color=black,')
        ..write('setsar=1,fps=$fps,format=yuv420p');
      if (c.filter.ffmpeg != null) v.write(',${c.filter.ffmpeg}');
      v.write('[v$i]');
      filters.add(v.toString());

      if (c.hasAudio) {
        filters.add(
          '[$vIdx:a]atrim=start=$start:end=$end,asetpts=PTS-STARTPTS,'
          'atempo=${speed.toStringAsFixed(3)},'
          'volume=${c.volume.toStringAsFixed(2)},$_audioFormat[a$i]',
        );
      } else {
        final d = _s(c.outputDuration);
        args.addAll([
          '-f', 'lavfi', //
          '-t', d,
          '-i', 'anullsrc=r=44100:cl=stereo',
        ]);
        final nIdx = inputIndex++;
        filters.add('[$nIdx:a]atrim=duration=$d,asetpts=PTS-STARTPTS,'
            '$_audioFormat[a$i]');
      }
      concatInputs.write('[v$i][a$i]');
    }
    filters.add(
      '${concatInputs}concat=n=${project.clips.length}:v=1:a=1[vcat][acat]',
    );

    // 2) Testi.
    var vLabel = 'vcat';
    for (var i = 0; i < project.texts.length; i++) {
      final t = project.texts[i];
      final next = 'vt$i';
      final rgb = (t.color.toARGB32() & 0xFFFFFF)
          .toRadixString(16)
          .padLeft(6, '0');
      final y = switch (t.position) {
        TextPosition.top => 'h*0.08',
        TextPosition.center => '(h-text_h)/2',
        TextPosition.bottom => 'h*0.85-text_h',
      };
      final box = t.box
          ? ':box=1:boxcolor=black@0.45:boxborderw=24'
          : ':borderw=3:bordercolor=black@0.8';
      filters.add(
        "[$vLabel]drawtext=fontfile='${_esc(fontPath)}'"
        ":textfile='${_esc(textFilePaths[i])}':expansion=none"
        ':fontcolor=0x$rgb:fontsize=${t.fontSize.round()}'
        ':x=(w-text_w)/2:y=$y$box'
        ":enable='between(t,${_s(t.start)},${_s(t.end)})'[$next]",
      );
      vLabel = next;
    }

    // 3) Musica.
    var aLabel = 'acat';
    final music = project.music;
    if (music != null) {
      args.addAll([
        '-stream_loop', '-1', // ripete il brano se è più corto del video
        '-ss', _s(music.offset),
        '-i', music.path,
      ]);
      final mIdx = inputIndex++;
      filters.add(
        '[$mIdx:a]atrim=duration=${_s(project.totalDuration)},'
        'asetpts=PTS-STARTPTS,volume=${music.volume.toStringAsFixed(2)},'
        '$_audioFormat[mus]',
      );
      filters.add(
        '[acat][mus]amix=inputs=2:duration=first:'
        'dropout_transition=0:normalize=0[amix]',
      );
      aLabel = 'amix';
    }

    args.addAll([
      '-filter_complex', filters.join(';'),
      '-map', '[$vLabel]',
      '-map', '[$aLabel]',
      '-c:v', 'libx264',
      '-preset', 'veryfast',
      '-crf', '23',
      '-pix_fmt', 'yuv420p',
      '-c:a', 'aac',
      '-b:a', '192k',
      '-movflags', '+faststart',
      outputPath,
    ]);
    return args;
  }

  /// Secondi con 3 decimali, il formato che FFmpeg si aspetta.
  static String _s(Duration d) =>
      (d.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(3);

  /// Escape per valori racchiusi tra apici singoli nel filtergraph: dentro gli
  /// apici `:` e `,` sono già letterali, resta solo l'apice stesso.
  static String _esc(String path) => path.replaceAll("'", r"'\''");
}
