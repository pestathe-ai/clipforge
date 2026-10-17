import 'package:flutter/material.dart';

import '../models/project.dart';

String fmt(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final t = (d.inMilliseconds.remainder(1000) ~/ 100).toString();
  return '$m:$s.$t';
}

Duration _sec(double s) => Duration(microseconds: (s * 1e6).round());
double _toSec(Duration d) => d.inMicroseconds / 1e6;

Future<T?> _sheet<T>(BuildContext context, String title, Widget child) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
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
  );
}

/// Taglio: sceglie inizio e fine dentro la clip originale.
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
          labels: RangeLabels(fmt(clip.trimStart), fmt(clip.trimEnd)),
          onChanged: (v) {
            if (v.end - v.start < 0.2) return; // almeno 0,2 s
            setState(() {
              clip.trimStart = _sec(v.start);
              clip.trimEnd = _sec(v.end);
            });
          },
        ),
        Text('${fmt(clip.trimStart)} → ${fmt(clip.trimEnd)}'
            '   (${fmt(clip.trimEnd - clip.trimStart)})'),
        const SizedBox(height: 12),
        _done(ctx),
      ]);
    }),
  );
}

Future<bool?> showSpeedSheet(BuildContext context, VideoClip clip) {
  const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  return _sheet<bool>(
    context,
    'Velocità',
    StatefulBuilder(builder: (ctx, setState) {
      return Column(children: [
        Wrap(spacing: 8, children: [
          for (final s in speeds)
            ChoiceChip(
              label: Text('${s}x'),
              selected: clip.speed == s,
              onSelected: (_) => setState(() => clip.speed = s),
            ),
        ]),
        const SizedBox(height: 12),
        _done(ctx),
      ]);
    }),
  );
}

Future<bool?> showFilterSheet(BuildContext context, VideoClip clip) {
  return _sheet<bool>(
    context,
    'Filtro',
    StatefulBuilder(builder: (ctx, setState) {
      return Column(children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final f in VideoFilter.values)
            ChoiceChip(
              label: Text(f.label),
              selected: clip.filter == f,
              onSelected: (_) => setState(() => clip.filter = f),
            ),
        ]),
        const SizedBox(height: 12),
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
}) {
  var v = value;
  return _sheet<bool>(
    context,
    title,
    StatefulBuilder(builder: (ctx, setState) {
      return Column(children: [
        Slider(
          min: 0,
          max: 2,
          divisions: 20,
          value: v,
          label: '${(v * 100).round()}%',
          onChanged: (x) => setState(() {
            v = x;
            onChanged(x);
          }),
        ),
        _done(ctx),
      ]);
    }),
  );
}

const _textColors = [
  Colors.white,
  Color(0xFFFFE14D),
  Color(0xFF2EE6D6),
  Color(0xFFFF5C8A),
  Color(0xFF7CFF6B),
  Colors.black,
];

/// Crea o modifica un testo. Ritorna il testo, o null se annullato.
Future<TextOverlay?> showTextSheet(
  BuildContext context, {
  required Duration total,
  required Duration at,
  TextOverlay? existing,
}) {
  final draft = existing != null
      ? TextOverlay(
          text: existing.text,
          start: existing.start,
          end: existing.end,
          color: existing.color,
          fontSize: existing.fontSize,
          position: existing.position,
          box: existing.box,
        )
      : TextOverlay(
          text: '',
          start: at,
          end: at + const Duration(seconds: 3) > total
              ? total
              : at + const Duration(seconds: 3),
        );
  if (draft.end <= draft.start) {
    draft.start = Duration.zero;
    draft.end = total;
  }
  final controller = TextEditingController(text: draft.text);
  final maxS = _toSec(total);

  return _sheet<TextOverlay>(
    context,
    existing == null ? 'Aggiungi testo' : 'Modifica testo',
    StatefulBuilder(builder: (ctx, setState) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          controller: controller,
          autofocus: existing == null,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: 'Scrivi qualcosa…',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: [
          for (final c in _textColors)
            GestureDetector(
              onTap: () => setState(() => draft.color = c),
              child: Container(
                width: 32,
                height: 32,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: draft.color == c ? Colors.white : Colors.white24,
                    width: draft.color == c ? 3 : 1,
                  ),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 12),
        SegmentedButton<TextPosition>(
          segments: [
            for (final p in TextPosition.values)
              ButtonSegment(value: p, label: Text(p.label)),
          ],
          selected: {draft.position},
          onSelectionChanged: (s) => setState(() => draft.position = s.first),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Sfondo dietro al testo'),
          value: draft.box,
          onChanged: (v) => setState(() => draft.box = v),
        ),
        Text('Dimensione  ${draft.fontSize.round()}'),
        Slider(
          min: 32,
          max: 140,
          value: draft.fontSize,
          onChanged: (v) => setState(() => draft.fontSize = v),
        ),
        Text('Visibile da ${fmt(draft.start)} a ${fmt(draft.end)}'),
        RangeSlider(
          min: 0,
          max: maxS,
          values: RangeValues(_toSec(draft.start), _toSec(draft.end)),
          onChanged: (v) {
            if (v.end - v.start < 0.3) return;
            setState(() {
              draft.start = _sec(v.start);
              draft.end = _sec(v.end);
            });
          },
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isEmpty) return;
              draft.text = text;
              Navigator.pop(ctx, draft);
            },
            child: const Text('Salva'),
          ),
        ),
      ]);
    }),
  );
}

Widget _done(BuildContext ctx) => SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: () => Navigator.pop(ctx, true),
        child: const Text('Fatto'),
      ),
    );
