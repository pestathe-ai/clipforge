import 'dart:io';

import 'package:flutter/material.dart';

import '../models/project.dart';
import '../services/ai_spot_service.dart' show ShotRole;
import '../services/spot_service.dart';

/// Opzioni dello spot gratuito: cosa mostra ogni foto, marchio, formato.
Future<SpotRequest?> showSpotSheet(BuildContext context, List<String> photos) {
  final roles = <ShotRole>[
    for (var i = 0; i < photos.length; i++)
      i == 0
          ? ShotRole.hero
          : const [ShotRole.dial, ShotRole.crown, ShotRole.caseback, ShotRole.logo, ShotRole.strap, ShotRole.box]
              [(i - 1) % 6],
  ];
  final brand = TextEditingController();
  final endLine = TextEditingController();
  var aspect = AspectRatioPreset.portrait;

  return showModalBottomSheet<SpotRequest>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFF1A1B20),
    builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
      return Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.88),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Spot prodotto', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 4),
              const Text(
                'Gratis, tutto sul telefono. Indica cosa mostra ogni foto: '
                '"Intero" diventa l\'inquadratura finale, ritagliata su nero.',
                style: TextStyle(fontSize: 13, color: Colors.white60),
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < photos.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(File(photos[i]), width: 64, height: 84, fit: BoxFit.cover, cacheWidth: 200),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Wrap(spacing: 6, runSpacing: 4, children: [
                        for (final r in ShotRole.values)
                          ChoiceChip(
                            visualDensity: VisualDensity.compact,
                            label: Text(r.label, style: const TextStyle(fontSize: 12)),
                            selected: roles[i] == r,
                            onSelected: (_) => setState(() {
                              // Una sola foto "Intero".
                              if (r == ShotRole.hero) {
                                for (var j = 0; j < roles.length; j++) {
                                  if (roles[j] == ShotRole.hero) roles[j] = ShotRole.dial;
                                }
                              }
                              roles[i] = r;
                            }),
                          ),
                      ]),
                    ),
                  ]),
                ),
              TextField(
                controller: brand,
                decoration: const InputDecoration(labelText: 'Marchio (es. Bulova)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: endLine,
                decoration: const InputDecoration(
                    labelText: 'Riga finale (facoltativa, es. Classic)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              Wrap(spacing: 8, children: [
                for (final a in [AspectRatioPreset.portrait, AspectRatioPreset.classic, AspectRatioPreset.square])
                  ChoiceChip(label: Text(a.label), selected: aspect == a, onSelected: (_) => setState(() => aspect = a)),
              ]),
              const SizedBox(height: 8),
              const Text(
                'Consiglio: foto nitide, da vicino, con poca luce sullo sfondo. '
                'La prima volta il telefono scarica il modello di ritaglio di Google (gratuito).',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(
                    ctx,
                    SpotRequest(
                      photos: [for (var i = 0; i < photos.length; i++) (photos[i], roles[i])],
                      brand: brand.text,
                      endLine: endLine.text,
                      aspect: aspect,
                    ),
                  ),
                  icon: const Icon(Icons.movie_creation_rounded),
                  label: const Text('Crea spot'),
                ),
              ),
            ]),
          ),
        ),
      );
    }),
  );
}
