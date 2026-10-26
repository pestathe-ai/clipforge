import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/project.dart';
import 'ffmpeg_service.dart';
import 'higgsfield_service.dart';
import 'spot_service.dart' show analyzePhoto;

/// Cosa mostra una foto: decide il tipo di ripresa (e il prompt).
enum ShotRole {
  hero('Intero', Icons.watch_rounded, 4),
  dial('Quadrante', Icons.radio_button_checked_rounded, 3),
  logo('Logo', Icons.text_fields_rounded, 3),
  crown('Corona', Icons.settings_rounded, 3),
  caseback('Fondello', Icons.flip_rounded, 3),
  strap('Cinturino', Icons.link_rounded, 3),
  box('Scatola', Icons.inventory_2_rounded, 3);

  const ShotRole(this.label, this.icon, this.seconds);
  final String label;
  final IconData icon;
  final int seconds;
}

/// Ordine di montaggio, come negli spot dei grandi marchi:
/// apertura, frammenti macro, chiusura con l'oggetto intero.
const shotOrder = [
  ShotRole.box,
  ShotRole.dial,
  ShotRole.logo,
  ShotRole.crown,
  ShotRole.caseback,
  ShotRole.strap,
  ShotRole.hero,
];

class AiSpotRequest {
  AiSpotRequest({
    required this.photos,
    required this.brand,
    this.endLine = '',
    this.aspect = AspectRatioPreset.portrait,
  });

  /// Foto con il loro ruolo.
  final List<(String, ShotRole)> photos;
  final String brand;
  final String endLine;
  final AspectRatioPreset aspect;
}

/// Prompt in stile pubblicità di orologi di lusso (inglese: i modelli
/// video rendono meglio).
class AiSpotPrompts {
  static String style(String brand) => 'Luxury ${brand.trim().isEmpty ? 'watch' : '${brand.trim()} watch'} '
      'commercial. Use the input image as the exact product reference: preserve brand name, logo, '
      'dial, hands, markers, case, crown and strap exactly as they are. Do not redesign, distort, '
      'morph, add or remove any detail, and do not invent new text. Deep black low-key studio, '
      'controlled warm highlights, elegant reflections on polished steel and crystal, very shallow '
      'depth of field. Slow, refined, luxurious pacing; extremely smooth, controlled cinematic camera. '
      'No people, no hands, no added text or graphics.';

  static String shot(ShotRole r) => switch (r) {
        ShotRole.box => 'The watch resting in its presentation box. Slow, elegant push-in toward the '
            'watch; soft light gradually reveals the dial from the darkness.',
        ShotRole.dial => 'Extreme macro of the watch dial. Very slow lateral camera move with an '
            'extremely subtle push-in; focus locked on the centre of the dial while the edges fall softly '
            'out of focus. A narrow warm highlight slowly travels across the dial, revealing the indices, '
            'hands and dial texture. The hands stay fixed.',
        ShotRole.logo => 'Extreme macro of the brand logo and typography on the dial. Slow diagonal '
            'camera move from lower-left toward upper-right with an extremely subtle push-in. A '
            'controlled warm highlight gently passes across the logo and nearby markers.',
        ShotRole.crown => 'Low side-angle macro, almost parallel to the case. Slowly track along the '
            'polished case flank toward the crown; the crown comes into crisp focus as light glints on '
            'its edges.',
        ShotRole.caseback => 'Extreme macro of the engraved case back. Very slow rotation with a subtle '
            'push-in; a soft highlight sweeps across the engravings and the polished steel.',
        ShotRole.strap => 'Low side-angle macro of the strap, not front-facing. Slowly track along it '
            'toward the case with very shallow depth of field; reflections travel across its edges and '
            'texture.',
        ShotRole.hero => 'The complete watch in a powerful luxury hero composition on deep black, case, '
            'dial, crown and strap visible. Extremely slow cinematic push-in with a very subtle upward '
            'camera movement. A warm highlight slowly sweeps across the case. End on a still, perfectly '
            'lit hero frame.',
      };

  /// Un'unica foto: tutte le inquadrature generate dalla stessa immagine
  /// (Kling "multi-shot"), come nell'esempio di Higgsfield.
  static List<Map<String, dynamic>> multiShot() => [
        for (final r in [ShotRole.dial, ShotRole.logo, ShotRole.crown, ShotRole.hero])
          {'prompt': _clip(shot(r), 512), 'duration': r.seconds},
      ];

  static String _clip(String s, int n) => s.length <= n ? s : s.substring(0, n);
}

/// Una ripresa da generare.
class AiShot {
  AiShot(this.role, this.photo);
  final ShotRole role;
  final String photo;
  JobState? state;
  String? error;
  String? file;
}

/// Genera lo spot con Higgsfield (Kling 3.0 image-to-video) e lo monta.
class AiSpotService {
  AiSpotService(this.client, this.ffmpeg);
  final HiggsfieldClient client;
  final FFmpegService ffmpeg;

  static const model = 'kling-video/v3.0/std/image-to-video';

  /// Costo indicativo (Kling 3.0 su Higgsfield ≈ 0,112 $/s).
  static double estimateUsd(List<(String, ShotRole)> photos) {
    final shots = plan(photos);
    final secs = shots.length == 1 && photos.length == 1
        ? AiSpotPrompts.multiShot().fold<int>(0, (a, s) => a + (s['duration'] as int))
        : shots.fold<int>(0, (a, s) => a + s.role.seconds);
    return secs * 0.112;
  }

  /// Una ripresa per ruolo, nell'ordine di montaggio. Con una foto sola si
  /// fa una richiesta multi-inquadratura.
  static List<AiShot> plan(List<(String, ShotRole)> photos) {
    if (photos.length == 1) return [AiShot(ShotRole.hero, photos.first.$1)];
    final out = <AiShot>[];
    for (final role in shotOrder) {
      for (final (path, r) in photos) {
        if (r == role) out.add(AiShot(role, path));
      }
    }
    // Chiudi sempre sull'intero: se manca, usa la prima foto.
    if (!out.any((s) => s.role == ShotRole.hero)) out.add(AiShot(ShotRole.hero, photos.first.$1));
    return out;
  }

  Future<Project> run(
    AiSpotRequest req, {
    required void Function(List<AiShot> shots, String phase) onUpdate,
    bool Function()? cancelled,
  }) async {
    final shots = plan(req.photos);
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'media', 'ai_spot_${DateTime.now().millisecondsSinceEpoch}'));
    await dir.create(recursive: true);
    final single = req.photos.length == 1;

    // 1) Prepara e carica le foto (ritagliate nel formato del video).
    final uploaded = <String, String>{};
    for (var i = 0; i < shots.length; i++) {
      final s = shots[i];
      if (uploaded.containsKey(s.photo)) continue;
      onUpdate(shots, 'Carico le foto (${uploaded.length + 1})…');
      final prepared = await _prepare(s.photo, p.join(dir.path, 'in_$i.png'), req.aspect);
      uploaded[s.photo] = await client.upload(prepared, 'image/png');
    }

    // 2) Avvia tutte le riprese in parallelo e attendi.
    onUpdate(shots, 'Higgsfield sta girando le riprese…');
    await Future.wait([
      for (var i = 0; i < shots.length; i++)
        () async {
          final s = shots[i];
          try {
            final args = <String, dynamic>{
              'prompt': single
                  ? AiSpotPrompts.style(req.brand)
                  : '${AiSpotPrompts.style(req.brand)}\n\n${AiSpotPrompts.shot(s.role)}',
              'image_url': uploaded[s.photo],
              'sound': 'off',
              if (single) ...{'multi_shots': true, 'multi_prompt': AiSpotPrompts.multiShot()}
              else 'duration': s.role.seconds,
            };
            final statusUrl = await client.submit(model, args);
            s.state = JobState.queued;
            onUpdate(shots, 'Higgsfield sta girando le riprese…');
            final url = await client.wait(statusUrl, cancelled: cancelled, onState: (st) {
              s.state = st;
              onUpdate(shots, 'Higgsfield sta girando le riprese…');
            });
            final file = p.join(dir.path, 'shot_${i}_${s.role.name}.mp4');
            await downloadTo(url, file);
            s.file = file;
            s.state = JobState.completed;
          } catch (e) {
            s.state = JobState.failed;
            s.error = '$e';
          }
          onUpdate(shots, 'Higgsfield sta girando le riprese…');
        }(),
    ]);
    final ok = shots.where((s) => s.file != null).toList();
    if (ok.isEmpty) {
      throw HiggsfieldException(shots.map((s) => s.error).whereType<String>().firstOrNull ??
          'Nessuna ripresa generata.');
    }

    // 3) Montaggio: tagli secchi, chiusura con il marchio.
    onUpdate(shots, 'Monto lo spot…');
    final project = Project(aspect: req.aspect)..background = CanvasBackground.black;
    for (final s in ok) {
      final info = await ffmpeg.probe(s.file!);
      project.clips.add(VideoClip(
        path: s.file!,
        sourceDuration: info.duration,
        hasAudio: info.hasAudio,
        width: info.width,
        height: info.height,
      ));
    }
    final total = project.totalDuration;
    final title = req.brand.trim().toUpperCase();
    final endStart = total - const Duration(milliseconds: 2400);
    if (title.isNotEmpty && endStart > Duration.zero) {
      project.overlays.add(VideoOverlay(
        kind: OverlayKind.text,
        text: title,
        start: endStart,
        end: total,
        color: const Color(0xFFF2F2F2),
        fontSize: 78,
        outline: false,
        cy: 0.84,
        animIn: AnimIn.fade,
        animOut: AnimOut.none,
      ));
    }
    if (req.endLine.trim().isNotEmpty && endStart > Duration.zero) {
      project.overlays.add(VideoOverlay(
        kind: OverlayKind.text,
        text: req.endLine.trim(),
        start: endStart + const Duration(milliseconds: 500),
        end: total,
        color: const Color(0xFFE6C77A),
        fontSize: 42,
        outline: false,
        cy: 0.9,
        animIn: AnimIn.fade,
        animOut: AnimOut.none,
      ));
    }
    return project;
  }

  /// Ritaglia la foto nel formato del video, centrata sull'oggetto,
  /// e la riduce a massimo 1920 px (orientamento EXIF rispettato).
  static Future<String> _prepare(String src, String out, AspectRatioPreset aspect) async {
    final bytes = await File(src).readAsBytes();
    final probe = (await (await ui.instantiateImageCodec(bytes)).getNextFrame()).image;
    final w = probe.width.toDouble(), h = probe.height.toDouble();
    probe.dispose();

    // Centro dell'oggetto dall'analisi della foto ridotta.
    var cx = w / 2, cy = h / 2;
    try {
      const aw = 256;
      final ah = math.max(8, (aw * h / w).round());
      final small = (await (await ui.instantiateImageCodec(bytes, targetWidth: aw, targetHeight: ah)).getNextFrame()).image;
      final rgba = (await small.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      small.dispose();
      final r = await Isolate.run(() => analyzePhoto(rgba, aw, ah));
      cx = (r[0] + r[2] / 2) * w / aw;
      cy = (r[1] + r[3] / 2) * h / ah;
    } catch (_) {}

    final a = aspect.ratio;
    var cw = w, ch = w / a;
    if (ch > h) {
      ch = h;
      cw = h * a;
    }
    final left = (cx - cw / 2).clamp(0.0, w - cw);
    final top = (cy - ch / 2).clamp(0.0, h - ch);
    final k = math.min(1.0, 1920 / math.max(cw, ch));
    final ow = (cw * k).round(), oh = (ch * k).round();

    final full = (await (await ui.instantiateImageCodec(bytes)).getNextFrame()).image;
    final rec = ui.PictureRecorder();
    Canvas(rec).drawImageRect(full, Rect.fromLTWH(left, top, cw, ch), Rect.fromLTWH(0, 0, ow.toDouble(), oh.toDouble()),
        Paint()..filterQuality = FilterQuality.high);
    full.dispose();
    final img = await rec.endRecording().toImage(ow, oh);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    await File(out).writeAsBytes(png!.buffer.asUint8List(), flush: true);
    return out;
  }
}
