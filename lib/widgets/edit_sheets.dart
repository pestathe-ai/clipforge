import 'package:flutter/material.dart';

import '../models/project.dart';
import '../models/templates.dart';

String fmt(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final t = (d.inMilliseconds.remainder(1000) ~/ 100).toString();
  return '$m:$s.$t';
}

Duration _sec(double s) => Duration(microseconds: (s * 1e6).round());
double _toSec(Duration d) => d.inMicroseconds / 1e6;

Future<T?> _sheet<T>(BuildContext context, String title, Widget child,
    {bool scroll = false}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFF1A1B20),
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.75),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 16),
              child,
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _done(BuildContext ctx) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Fatto'),
        ),
      ),
    );

/// Griglia di scelte con icona (filtri, effetti, transizioni...).
class _ChoiceGrid<T> extends StatelessWidget {
  const _ChoiceGrid({
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelect,
    this.icon,
    this.preview,
  });

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final IconData Function(T)? icon;
  final Widget Function(T)? preview;
  final ValueChanged<T> onSelect;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 0.85,
      children: [
        for (final v in values)
          GestureDetector(
            onTap: () => onSelect(v),
            child: Column(children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2B31),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: v == selected ? accent : Colors.transparent, width: 2.5),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Center(
                    child: preview != null
                        ? preview!(v)
                        : Icon(icon?.call(v), color: v == selected ? accent : Colors.white70),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(label(v),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      color: v == selected ? accent : Colors.white70,
                      fontWeight: v == selected ? FontWeight.w700 : FontWeight.w400)),
            ]),
          ),
      ],
    );
  }
}

// ─────────────────────────── Clip ───────────────────────────

Future<bool?> showTrimSheet(BuildContext context, VideoClip clip) {
  return _sheet<bool>(
    context,
    'Taglia',
    StatefulBuilder(builder: (ctx, setState) {
      final max = _toSec(clip.sourceDuration);
      return Column(children: [
        RangeSlider(
          min: 0,
          max: max,
          values: RangeValues(_toSec(clip.trimStart), _toSec(clip.trimEnd)),
          onChanged: (v) {
            if (v.end - v.start < 0.3) return;
            setState(() {
              clip.trimStart = _sec(v.start);
              clip.trimEnd = _sec(v.end);
            });
          },
        ),
        Text('${fmt(clip.trimStart)} → ${fmt(clip.trimEnd)}'
            '   (${fmt(clip.trimEnd - clip.trimStart)})'),
        _done(ctx),
      ]);
    }),
  );
}

Future<bool?> showSpeedSheet(BuildContext context, VideoClip clip) {
  const presets = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  return _sheet<bool>(
    context,
    'Velocità',
    StatefulBuilder(builder: (ctx, setState) {
      return Column(children: [
        Text('${clip.speed.toStringAsFixed(2)}x',
            style: Theme.of(ctx).textTheme.headlineSmall),
        Slider(
          min: 0.5,
          max: 2.0,
          divisions: 30,
          value: clip.speed,
          onChanged: (v) => setState(() => clip.speed = double.parse(v.toStringAsFixed(2))),
        ),
        Wrap(spacing: 8, children: [
          for (final s in presets)
            ChoiceChip(
              label: Text('${s}x'),
              selected: clip.speed == s,
              onSelected: (_) => setState(() => clip.speed = s),
            ),
        ]),
        _done(ctx),
      ]);
    }),
  );
}

Future<bool?> showFilterSheet(BuildContext context, VideoClip clip, {VoidCallback? applyToAll}) {
  return _sheet<bool>(
    context,
    'Filtri',
    StatefulBuilder(builder: (ctx, setState) {
      return Column(children: [
        _ChoiceGrid<VideoFilter>(
          values: VideoFilter.values,
          selected: clip.filter,
          label: (f) => f.label,
          preview: (f) {
            final m = f.previewMatrix;
            const swatch = DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFFFF7A59), Color(0xFFFFD25A), Color(0xFF3FC1FF)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: SizedBox.expand(),
            );
            return m == null ? swatch : ColorFiltered(colorFilter: ColorFilter.matrix(m), child: swatch);
          },
          onSelect: (f) => setState(() => clip.filter = f),
        ),
        if (applyToAll != null)
          TextButton.icon(
            onPressed: applyToAll,
            icon: const Icon(Icons.done_all_rounded),
            label: const Text('Applica a tutte le clip'),
          ),
        _done(ctx),
      ]);
    }),
  );
}

Future<bool?> showEffectSheet(BuildContext context, VideoClip clip) {
  return _sheet<bool>(
    context,
    'Effetti',
    StatefulBuilder(builder: (ctx, setState) {
      return Column(children: [
        _ChoiceGrid<ClipEffect>(
          values: ClipEffect.values,
          selected: clip.effect,
          label: (e) => e.label,
          icon: (e) => e.icon,
          onSelect: (e) => setState(() => clip.effect = e),
        ),
        _done(ctx),
      ]);
    }),
  );
}

Future<bool?> showTransitionSheet(BuildContext context, VideoClip clip, {VoidCallback? applyToAll}) {
  return _sheet<bool>(
    context,
    'Transizione',
    StatefulBuilder(builder: (ctx, setState) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _ChoiceGrid<TransitionType>(
          values: TransitionType.values,
          selected: clip.transition,
          label: (t) => t.label,
          icon: (t) => t.icon,
          onSelect: (t) => setState(() => clip.transition = t),
        ),
        const SizedBox(height: 12),
        Text('Durata ${(clip.transitionDuration.inMilliseconds / 1000).toStringAsFixed(1)} s'),
        Slider(
          min: 0.2,
          max: 2.0,
          divisions: 18,
          value: (clip.transitionDuration.inMilliseconds / 1000).clamp(0.2, 2.0),
          onChanged: clip.transition == TransitionType.none
              ? null
              : (v) => setState(() => clip.transitionDuration = _sec(v)),
        ),
        if (applyToAll != null)
          TextButton.icon(
            onPressed: applyToAll,
            icon: const Icon(Icons.done_all_rounded),
            label: const Text('Applica a tutte le clip'),
          ),
        _done(ctx),
      ]);
    }),
  );
}

Future<bool?> showVolumeSheet(
  BuildContext context, {
  required String title,
  required double value,
  required ValueChanged<double> onChanged,
  bool? fadeOut,
  ValueChanged<bool>? onFadeOut,
}) {
  var v = value;
  var f = fadeOut;
  return _sheet<bool>(
    context,
    title,
    StatefulBuilder(builder: (ctx, setState) {
      return Column(children: [
        Text('${(v * 100).round()}%', style: Theme.of(ctx).textTheme.headlineSmall),
        Slider(
          min: 0,
          max: 2,
          divisions: 20,
          value: v,
          onChanged: (x) => setState(() {
            v = x;
            onChanged(x);
          }),
        ),
        if (f != null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Dissolvenza finale'),
            value: f!,
            onChanged: (x) => setState(() {
              f = x;
              onFadeOut?.call(x);
            }),
          ),
        _done(ctx),
      ]);
    }),
  );
}

// ─────────────────────────── Testo ───────────────────────────

const textColors = [
  Colors.white,
  Colors.black,
  Color(0xFFFFE14D),
  Color(0xFFFF5C8A),
  Color(0xFF2EE6D6),
  Color(0xFF7CFF6B),
  Color(0xFFFF8A3D),
  Color(0xFFB98CFF),
];

/// Stili rapidi in stile CapCut.
const _textPresets = <(String, Color, bool, Color, bool)>[
  // nome, colore, box, colore box, contorno
  ('Classico', Colors.white, false, Color(0x00000000), true),
  ('Etichetta', Colors.white, true, Color(0xCC000000), false),
  ('Giallo', Colors.black, true, Color(0xFFFFE14D), false),
  ('Neon', Color(0xFF2EE6D6), false, Color(0x00000000), true),
  ('Rosa', Colors.white, true, Color(0xFFFF5C8A), false),
  ('Semplice', Colors.white, false, Color(0x00000000), false),
];

/// Crea o modifica un testo. Lavora su una copia e ritorna il risultato
/// (o null se annullato).
Future<VideoOverlay?> showTextSheet(
  BuildContext context, {
  required Duration total,
  required Duration at,
  VideoOverlay? existing,
}) {
  final o = existing?.copy() ??
      VideoOverlay(
        kind: OverlayKind.text,
        text: '',
        start: at,
        end: at + const Duration(seconds: 3) > total ? total : at + const Duration(seconds: 3),
        cy: 0.5,
      );
  if (o.end <= o.start) {
    o.start = Duration.zero;
    o.end = total;
  }
  final controller = TextEditingController(text: o.text);

  return _sheet<VideoOverlay>(
    context,
    existing == null ? 'Aggiungi testo' : 'Modifica testo',
    StatefulBuilder(builder: (ctx, setState) {
      Widget section(String t) => Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 6),
            child: Text(t, style: const TextStyle(color: Colors.white60, fontSize: 12)),
          );
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          controller: controller,
          autofocus: existing == null,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(hintText: 'Scrivi qualcosa…', border: OutlineInputBorder()),
        ),
        section('STILE'),
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final pr in _textPresets)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ActionChip(
                  label: Text(pr.$1, style: TextStyle(color: pr.$3 ? pr.$2 : null)),
                  backgroundColor: pr.$3 ? pr.$4 : null,
                  onPressed: () => setState(() {
                    o.color = pr.$2;
                    o.box = pr.$3;
                    if (pr.$3) o.boxColor = pr.$4;
                    o.outline = pr.$5;
                  }),
                ),
              ),
          ]),
        ),
        section('COLORE'),
        Wrap(spacing: 10, runSpacing: 10, children: [
          for (final c in textColors)
            GestureDetector(
              onTap: () => setState(() => o.color = c),
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: o.color == c ? Colors.white : Colors.white24, width: o.color == c ? 3 : 1),
                ),
              ),
            ),
        ]),
        Row(children: [
          Expanded(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Sfondo'),
              value: o.box,
              onChanged: (v) => setState(() => o.box = v),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Contorno'),
              value: o.outline,
              onChanged: (v) => setState(() => o.outline = v),
            ),
          ),
        ]),
        section('DIMENSIONE  ${o.fontSize.round()}'),
        Slider(min: 32, max: 180, value: o.fontSize.clamp(32, 180), onChanged: (v) => setState(() => o.fontSize = v)),
        section('ANIMAZIONE IN ENTRATA'),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final a in AnimIn.values)
            ChoiceChip(label: Text(a.label), selected: o.animIn == a, onSelected: (_) => setState(() => o.animIn = a)),
        ]),
        section('ANIMAZIONE IN USCITA'),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final a in AnimOut.values)
            ChoiceChip(label: Text(a.label), selected: o.animOut == a, onSelected: (_) => setState(() => o.animOut = a)),
        ]),
        const SizedBox(height: 8),
        const Text('Suggerimento: sull\'anteprima trascina il testo per spostarlo e '
            'usa due dita per ingrandirlo o ruotarlo.',
            style: TextStyle(fontSize: 12, color: Colors.white54)),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isEmpty) return;
              o.text = text;
              Navigator.pop(ctx, o);
            },
            child: const Text('Salva'),
          ),
        ),
      ]);
    }),
  );
}

// ─────────────────────────── Sticker ───────────────────────────

const _stickerGroups = <String, List<String>>{
  'Reazioni': ['😂', '😍', '🔥', '😎', '🤯', '😭', '🥳', '😱', '🤔', '🙄', '😴', '🤩', '😡', '🥺', '😇', '🤪'],
  'Gesti': ['👍', '👎', '👏', '🙌', '🙏', '💪', '✌️', '🤙', '👀', '👉', '👆', '🫶', '🤝', '✋', '🤘', '👋'],
  'Simboli': ['❤️', '💯', '✨', '⭐', '💥', '⚡', '💫', '❗', '❓', '✅', '❌', '⬆️', '➡️', '🎯', '🔔', '💬'],
  'Cose': ['🎉', '🎁', '🎵', '📸', '🎬', '💰', '🍕', '☕', '🍻', '⚽', '🏆', '🚀', '🌈', '☀️', '🌙', '🌊'],
};

Future<String?> showStickerSheet(BuildContext context) {
  return _sheet<String>(
    context,
    'Sticker',
    Builder(builder: (ctx) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final g in _stickerGroups.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Text(g.key, style: const TextStyle(color: Colors.white60, fontSize: 12)),
          ),
          GridView.count(
            crossAxisCount: 8,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final e in g.value)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => Navigator.pop(ctx, e),
                  child: Center(child: Text(e, style: const TextStyle(fontSize: 28))),
                ),
            ],
          ),
        ],
      ]);
    }),
  );
}

Future<bool?> showStickerAnimSheet(BuildContext context, VideoOverlay o) {
  return _sheet<bool>(
    context,
    'Animazione',
    StatefulBuilder(builder: (ctx, setState) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Entrata', style: TextStyle(color: Colors.white60, fontSize: 12)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final a in AnimIn.values)
            ChoiceChip(label: Text(a.label), selected: o.animIn == a, onSelected: (_) => setState(() => o.animIn = a)),
        ]),
        const SizedBox(height: 12),
        const Text('Uscita', style: TextStyle(color: Colors.white60, fontSize: 12)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final a in AnimOut.values)
            ChoiceChip(label: Text(a.label), selected: o.animOut == a, onSelected: (_) => setState(() => o.animOut = a)),
        ]),
        _done(ctx),
      ]);
    }),
  );
}

// ─────────────────────────── Formato ───────────────────────────

Future<bool?> showFormatSheet(BuildContext context, Project p) {
  return _sheet<bool>(
    context,
    'Formato e sfondo',
    StatefulBuilder(builder: (ctx, setState) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, children: [
          for (final a in AspectRatioPreset.values)
            ChoiceChip(label: Text(a.label), selected: p.aspect == a, onSelected: (_) => setState(() => p.aspect = a)),
        ]),
        const SizedBox(height: 16),
        const Text('Sfondo ai lati', style: TextStyle(color: Colors.white60, fontSize: 12)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          for (final b in CanvasBackground.values)
            ChoiceChip(label: Text(b.label), selected: p.background == b, onSelected: (_) => setState(() => p.background = b)),
        ]),
        _done(ctx),
      ]);
    }),
  );
}

// ─────────────────────────── Novità v0.3 ───────────────────────────

Future<bool?> showRotateSheet(BuildContext context, VideoClip clip) {
  return _sheet<bool>(
    context,
    'Ruota',
    StatefulBuilder(builder: (ctx, setState) {
      return Column(children: [
        Wrap(spacing: 8, children: [
          for (var q = 0; q < 4; q++)
            ChoiceChip(
              label: Text('${q * 90}°'),
              selected: clip.quarterTurns % 4 == q,
              onSelected: (_) => setState(() => clip.quarterTurns = q),
            ),
        ]),
        _done(ctx),
      ]);
    }),
  );
}

Future<bool?> showImageDurationSheet(BuildContext context, VideoClip clip) {
  return _sheet<bool>(
    context,
    'Durata foto',
    StatefulBuilder(builder: (ctx, setState) {
      final s = _toSec(clip.trimEnd - clip.trimStart);
      return Column(children: [
        Text('${s.toStringAsFixed(1)} s', style: Theme.of(ctx).textTheme.headlineSmall),
        Slider(
          min: 0.5,
          max: 15,
          divisions: 29,
          value: s.clamp(0.5, 15),
          onChanged: (v) => setState(() {
            clip.trimStart = Duration.zero;
            clip.trimEnd = _sec(v);
          }),
        ),
        _done(ctx),
      ]);
    }),
  );
}

Future<bool?> showAudioFxSheet(BuildContext context,
    {required AudioFx value, required bool denoise, required void Function(AudioFx fx, bool denoise) onChanged}) {
  var fx = value;
  var dn = denoise;
  return _sheet<bool>(
    context,
    'Effetti voce',
    StatefulBuilder(builder: (ctx, setState) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final f in AudioFx.values)
            ChoiceChip(
              label: Text(f.label),
              selected: fx == f,
              onSelected: (_) => setState(() {
                fx = f;
                onChanged(fx, dn);
              }),
            ),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Riduci rumore di fondo'),
          subtitle: const Text('Toglie fruscio, vento e brusio'),
          value: dn,
          onChanged: (v) => setState(() {
            dn = v;
            onChanged(fx, dn);
          }),
        ),
        const Text('Gli effetti si sentono nel video esportato.',
            style: TextStyle(fontSize: 12, color: Colors.white54)),
        _done(ctx),
      ]);
    }),
  );
}

Future<bool?> showMaskSheet(BuildContext context, PipLayer l) {
  return _sheet<bool>(
    context,
    'Maschera',
    StatefulBuilder(builder: (ctx, setState) {
      return Column(children: [
        _ChoiceGrid<MaskShape>(
          values: MaskShape.values,
          selected: l.mask,
          label: (m) => m.label,
          icon: (m) => m.icon,
          onSelect: (m) => setState(() => l.mask = m),
        ),
        _done(ctx),
      ]);
    }),
  );
}

const _chromaColors = <(String, Color)>[
  ('Verde', Color(0xFF00FF00)),
  ('Verde scuro', Color(0xFF00B140)),
  ('Blu', Color(0xFF0047BB)),
  ('Nero', Color(0xFF000000)),
  ('Bianco', Color(0xFFFFFFFF)),
];

Future<bool?> showChromaSheet(BuildContext context, PipLayer l) {
  return _sheet<bool>(
    context,
    'Chroma key (green screen)',
    StatefulBuilder(builder: (ctx, setState) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Rende trasparente il colore dello sfondo della sovrapposizione.',
            style: TextStyle(fontSize: 13, color: Colors.white60)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          ChoiceChip(
            label: const Text('Spento'),
            selected: l.chroma == null,
            onSelected: (_) => setState(() => l.chroma = null),
          ),
          for (final c in _chromaColors)
            ChoiceChip(
              avatar: CircleAvatar(backgroundColor: c.$2, radius: 8),
              label: Text(c.$1),
              selected: l.chroma?.toARGB32() == c.$2.toARGB32(),
              onSelected: (_) => setState(() => l.chroma = c.$2),
            ),
        ]),
        const SizedBox(height: 12),
        Text('Intensità ${(l.chromaSimilarity * 100).round()}'),
        Slider(
          min: 0.05,
          max: 0.6,
          value: l.chromaSimilarity.clamp(0.05, 0.6),
          onChanged: l.chroma == null ? null : (v) => setState(() => l.chromaSimilarity = v),
        ),
        const Text('Nell\'anteprima lo sfondo resta visibile: viene tolto nel video esportato.',
            style: TextStyle(fontSize: 12, color: Colors.white54)),
        _done(ctx),
      ]);
    }),
  );
}

Future<bool?> showOpacitySheet(BuildContext context, PipLayer l) {
  return _sheet<bool>(
    context,
    'Opacità',
    StatefulBuilder(builder: (ctx, setState) {
      return Column(children: [
        Text('${(l.opacity * 100).round()}%', style: Theme.of(ctx).textTheme.headlineSmall),
        Slider(min: 0.05, max: 1, value: l.opacity, onChanged: (v) => setState(() => l.opacity = v)),
        _done(ctx),
      ]);
    }),
  );
}

/// Movimento (keyframe): sposta un elemento da un punto a un altro.
Future<bool?> showMotionSheet(BuildContext context,
    {required bool enabled, required ValueChanged<bool> onChanged}) {
  var on = enabled;
  return _sheet<bool>(
    context,
    'Movimento (keyframe)',
    StatefulBuilder(builder: (ctx, setState) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Muovi durante la durata'),
          value: on,
          onChanged: (v) => setState(() {
            on = v;
            onChanged(v);
          }),
        ),
        const Text(
          'Come si usa:\n'
          '• porta la testina verso l\'INIZIO dell\'elemento e trascinalo dove deve partire;\n'
          '• porta la testina verso la FINE e trascinalo dove deve arrivare.\n'
          'Nel mezzo si sposta da solo.',
          style: TextStyle(fontSize: 13, color: Colors.white70, height: 1.4),
        ),
        _done(ctx),
      ]);
    }),
  );
}

Future<(ProjectTemplate, String)?> showTemplateSheet(BuildContext context, List<ProjectTemplate> templates) {
  final title = TextEditingController();
  return showModalBottomSheet<(ProjectTemplate, String)>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFF1A1B20),
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Modelli', style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: 4),
          const Text('Applicano stile, transizioni ed effetti a tutte le clip.',
              style: TextStyle(fontSize: 13, color: Colors.white60)),
          const SizedBox(height: 12),
          TextField(
            controller: title,
            decoration: const InputDecoration(
              labelText: 'Titolo (facoltativo)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final t in templates)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: Theme.of(ctx).colorScheme.primary.withValues(alpha: 0.2),
                    child: Icon(t.icon, color: Theme.of(ctx).colorScheme.primary),
                  ),
                  title: Text(t.name),
                  subtitle: Text(t.description, style: const TextStyle(fontSize: 12)),
                  onTap: () => Navigator.pop(ctx, (t, title.text.trim())),
                ),
            ]),
          ),
        ]),
      ),
    ),
  );
}
