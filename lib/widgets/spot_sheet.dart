import 'package:flutter/material.dart';

import '../models/project.dart';
import '../services/spot_service.dart';

/// Opzioni dello spot prodotto. Restituisce null se annullato.
Future<SpotOptions?> showSpotSheet(BuildContext context, int photoCount) {
  final title = TextEditingController();
  final subtitle = TextEditingController();
  final endText = TextEditingController();
  var style = SpotStyle.luxury;
  var seconds = 20;
  var aspect = AspectRatioPreset.portrait;

  return showModalBottomSheet<SpotOptions>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFF1A1B20),
    builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
      Widget label(String t) => Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 6),
            child: Text(t, style: const TextStyle(color: Colors.white60, fontSize: 12)),
          );
      return Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Spot prodotto', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('$photoCount foto · l\'app trova i dettagli e crea inquadrature macro in stile pubblicità.',
                style: const TextStyle(fontSize: 13, color: Colors.white60)),
            const SizedBox(height: 14),
            TextField(
              controller: title,
              decoration: const InputDecoration(
                  labelText: 'Nome (es. marca e modello)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: subtitle,
              decoration: const InputDecoration(
                  labelText: 'Sottotitolo (es. Automatico · 41 mm)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: endText,
              decoration: const InputDecoration(
                  labelText: 'Testo finale (es. prezzo o "Scrivimi in DM")', border: OutlineInputBorder()),
            ),
            label('STILE'),
            for (final s in SpotStyle.values)
              RadioListTile<SpotStyle>(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: s,
                groupValue: style,
                onChanged: (v) => setState(() => style = v!),
                title: Text(s.label),
                subtitle: Text(s.description, style: const TextStyle(fontSize: 12)),
              ),
            label('DURATA'),
            Wrap(spacing: 8, children: [
              for (final sec in [15, 20, 30])
                ChoiceChip(label: Text('$sec s'), selected: seconds == sec, onSelected: (_) => setState(() => seconds = sec)),
            ]),
            label('FORMATO'),
            Wrap(spacing: 8, children: [
              for (final a in [AspectRatioPreset.portrait, AspectRatioPreset.classic, AspectRatioPreset.square])
                ChoiceChip(label: Text(a.label), selected: aspect == a, onSelected: (_) => setState(() => aspect = a)),
            ]),
            const SizedBox(height: 8),
            const Text('Consiglio: foto nitide e da vicino, da più lati (fronte, lato, retro, corona, chiusura).',
                style: TextStyle(fontSize: 12, color: Colors.white54)),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.pop(
                  ctx,
                  SpotOptions(
                    title: title.text,
                    subtitle: subtitle.text,
                    endText: endText.text,
                    style: style,
                    seconds: seconds,
                    aspect: aspect,
                  ),
                ),
                icon: const Icon(Icons.auto_awesome_rounded),
                label: const Text('Crea spot'),
              ),
            ),
          ]),
        ),
      );
    }),
  );
}
