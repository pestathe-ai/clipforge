import 'package:flutter/material.dart';

import 'project.dart';

/// Modelli pronti: applicano in un colpo stile, transizioni, effetti e
/// titolo alle clip già presenti nel progetto.
class ProjectTemplate {
  const ProjectTemplate(this.name, this.description, this.icon, this.apply);
  final String name;
  final String description;
  final IconData icon;
  final void Function(Project p, String title) apply;
}

VideoOverlay _title(Project p, String text,
        {Color color = Colors.white,
        bool box = false,
        Color boxColor = const Color(0xCC000000),
        double cy = 0.45,
        double size = 110,
        AnimIn animIn = AnimIn.slideUp}) =>
    VideoOverlay(
      kind: OverlayKind.text,
      text: text,
      start: Duration.zero,
      end: p.totalDuration < const Duration(seconds: 3) ? p.totalDuration : const Duration(seconds: 3),
      color: color,
      fontSize: size,
      box: box,
      boxColor: boxColor,
      outline: !box,
      cy: cy,
      animIn: animIn,
      animOut: AnimOut.fade,
    );

void _each(Project p, void Function(VideoClip c, int i) f) {
  for (var i = 0; i < p.clips.length; i++) {
    f(p.clips[i], i);
  }
}

final projectTemplates = <ProjectTemplate>[
  ProjectTemplate('Vlog', 'Colori caldi, dissolvenze morbide, titolo con etichetta', Icons.videocam_rounded, (p, t) {
    _each(p, (c, i) {
      c.filter = VideoFilter.warm;
      c.transition = TransitionType.fade;
      c.transitionDuration = const Duration(milliseconds: 500);
      c.effect = c.isImage ? ClipEffect.zoomIn : ClipEffect.none;
    });
    if (t.isNotEmpty) p.overlays.add(_title(p, t, box: true, cy: 0.82, size: 80));
  }),
  ProjectTemplate('Sport / Azione', 'Ritmo veloce: glitch, flash, zoom e tremolio', Icons.bolt_rounded, (p, t) {
    const fx = [ClipEffect.flash, ClipEffect.shake, ClipEffect.zoomIn, ClipEffect.glitch];
    const tr = [TransitionType.zoom, TransitionType.slideLeft, TransitionType.fadeWhite, TransitionType.pixel];
    _each(p, (c, i) {
      c.filter = VideoFilter.contrast;
      c.effect = fx[i % fx.length];
      c.transition = tr[i % tr.length];
      c.transitionDuration = const Duration(milliseconds: 300);
    });
    if (t.isNotEmpty) {
      p.overlays.add(_title(p, t.toUpperCase(), color: const Color(0xFFFFE14D), size: 130, animIn: AnimIn.bounce));
    }
  }),
  ProjectTemplate('Cinematico', 'Tono film, bande nere 16:9, dissolvenze al nero', Icons.movie_rounded, (p, t) {
    p.aspect = AspectRatioPreset.landscape;
    p.background = CanvasBackground.black;
    _each(p, (c, i) {
      c.filter = VideoFilter.fade;
      c.effect = ClipEffect.zoomIn;
      c.transition = TransitionType.fadeBlack;
      c.transitionDuration = const Duration(milliseconds: 900);
    });
    if (t.isNotEmpty) p.overlays.add(_title(p, t, size: 90, cy: 0.5, animIn: AnimIn.fade));
  }),
  ProjectTemplate('Ricordi', 'Seppia, zoom lento e dissolvenze lunghe', Icons.photo_album_rounded, (p, t) {
    _each(p, (c, i) {
      c.filter = VideoFilter.sepia;
      c.effect = i.isEven ? ClipEffect.zoomIn : ClipEffect.zoomOut;
      c.transition = TransitionType.fade;
      c.transitionDuration = const Duration(milliseconds: 1000);
    });
    if (t.isNotEmpty) p.overlays.add(_title(p, t, cy: 0.8, size: 90, animIn: AnimIn.fade));
  }),
  ProjectTemplate('Retrò VHS', 'Effetto videocassetta e tagli netti', Icons.videogame_asset_rounded, (p, t) {
    _each(p, (c, i) {
      c.filter = VideoFilter.none;
      c.effect = ClipEffect.vhs;
      c.transition = i.isEven ? TransitionType.none : TransitionType.blur;
      c.transitionDuration = const Duration(milliseconds: 400);
    });
    if (t.isNotEmpty) {
      p.overlays.add(_title(p, t, color: const Color(0xFF2EE6D6), cy: 0.12, size: 80, animIn: AnimIn.slideLeft));
    }
  }),
  ProjectTemplate('Social / Reel', '9:16, sfondo sfocato, colori vivaci, titolo giallo', Icons.phone_iphone_rounded, (p, t) {
    p.aspect = AspectRatioPreset.portrait;
    p.background = CanvasBackground.blur;
    _each(p, (c, i) {
      c.filter = VideoFilter.vivid;
      c.transition = TransitionType.slideUp;
      c.transitionDuration = const Duration(milliseconds: 350);
    });
    if (t.isNotEmpty) {
      p.overlays.add(_title(p, t, color: Colors.black, box: true, boxColor: const Color(0xFFFFE14D), cy: 0.2, size: 84));
    }
  }),
  ProjectTemplate('Bianco e nero', 'Noir elegante con dissolvenze', Icons.contrast_rounded, (p, t) {
    _each(p, (c, i) {
      c.filter = VideoFilter.noir;
      c.effect = ClipEffect.vignette;
      c.transition = TransitionType.fade;
      c.transitionDuration = const Duration(milliseconds: 700);
    });
    if (t.isNotEmpty) p.overlays.add(_title(p, t, size: 96, animIn: AnimIn.fade));
  }),
];
