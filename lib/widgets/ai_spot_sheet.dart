import 'dart:io';

import 'package:flutter/material.dart';

import '../models/project.dart';
import '../services/ai_spot_service.dart';
import '../services/higgsfield_service.dart';

/// Chiede e salva la chiave API di Higgsfield. Restituisce la chiave o null.
Future<String?> showHiggsfieldKeySheet(BuildContext context) async {
  final current = await HiggsfieldKeyStore.load();
  if (!context.mounted) return null;
  final ctrl = TextEditingController(text: current ?? '');
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFF1A1B20),
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Chiave Higgsfield', style: Theme.of(ctx).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          '1. Vai su cloud.higgsfield.ai e accedi.\n'
          '2. Ricarica il saldo API (è separato dall\'abbonamento dell\'app Higgsfield).\n'
          '3. Crea una chiave: ti dà KEY ID e KEY SECRET.\n'
          '4. Incollali qui nel formato  KEY_ID:KEY_SECRET',
          style: TextStyle(fontSize: 13, color: Colors.white70, height: 1.45),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: ctrl,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'KEY_ID:KEY_SECRET', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        Row(children: [
          if (current != null)
            TextButton(
              onPressed: () async {
                await HiggsfieldKeyStore.clear();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Rimuovi'),
            ),
          const Spacer(),
          FilledButton(
            onPressed: () async {
              final k = ctrl.text.trim();
              if (!k.contains(':')) return;
              await HiggsfieldKeyStore.save(k);
              if (ctx.mounted) Navigator.pop(ctx, k);
            },
            child: const Text('Salva'),
          ),
        ]),
      ]),
    ),
  );
}

/// Opzioni dello spot IA: ruolo di ogni foto, marchio, formato.
Future<AiSpotRequest?> showAiSpotSheet(BuildContext context, List<String> photos) {
  final roles = <ShotRole>[
    for (var i = 0; i < photos.length; i++) i == 0 ? ShotRole.hero : const [
      ShotRole.dial, ShotRole.logo, ShotRole.crown, ShotRole.caseback, ShotRole.strap, ShotRole.box,
    ][(i - 1) % 6],
  ];
  final brand = TextEditingController();
  final endLine = TextEditingController();
  var aspect = AspectRatioPreset.portrait;

  return showModalBottomSheet<AiSpotRequest>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFF1A1B20),
    builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
      final pairs = [for (var i = 0; i < photos.length; i++) (photos[i], roles[i])];
      final usd = AiSpotService.estimateUsd(pairs);
      final shots = AiSpotService.plan(pairs);
      return Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.88),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Spot IA', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 4),
              const Text('Higgsfield gira una ripresa per ogni foto. Indica cosa mostra ognuna.',
                  style: TextStyle(fontSize: 13, color: Colors.white60)),
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
                            onSelected: (_) => setState(() => roles[i] = r),
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
                    labelText: 'Frase finale (facoltativa, es. modello o prezzo)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              Wrap(spacing: 8, children: [
                for (final a in [AspectRatioPreset.portrait, AspectRatioPreset.classic, AspectRatioPreset.square])
                  ChoiceChip(label: Text(a.label), selected: aspect == a, onSelected: (_) => setState(() => aspect = a)),
              ]),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: const Color(0xFF24252B), borderRadius: BorderRadius.circular(12)),
                child: Text(
                  photos.length == 1
                      ? '1 foto: Higgsfield crea 4 inquadrature dalla stessa immagine.\n'
                          'Costo stimato ≈ ${usd.toStringAsFixed(2)} \$ (pagato dal tuo saldo API Higgsfield).'
                      : '${shots.length} riprese: ${shots.map((s) => s.role.label).join(' → ')}\n'
                          'Costo stimato ≈ ${usd.toStringAsFixed(2)} \$ (pagato dal tuo saldo API Higgsfield).',
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(
                    ctx,
                    AiSpotRequest(photos: pairs, brand: brand.text, endLine: endLine.text, aspect: aspect),
                  ),
                  icon: const Icon(Icons.movie_creation_rounded),
                  label: const Text('Genera con Higgsfield'),
                ),
              ),
            ]),
          ),
        ),
      );
    }),
  );
}

/// Stato delle riprese durante la generazione.
class AiSpotProgress extends StatelessWidget {
  const AiSpotProgress({super.key, required this.shots, required this.phase});
  final List<AiShot> shots;
  final String phase;

  @override
  Widget build(BuildContext context) {
    String label(AiShot s) => switch (s.state) {
          null => 'in attesa',
          JobState.queued => 'in coda',
          JobState.inProgress => 'in lavorazione…',
          JobState.completed => 'pronta ✓',
          JobState.nsfw => 'bloccata',
          JobState.canceled => 'annullata',
          JobState.failed => 'non riuscita',
        };
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(phase),
      const SizedBox(height: 12),
      for (final s in shots)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Icon(s.role.icon, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(s.role.label)),
            Text(label(s), style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ]),
        ),
      const SizedBox(height: 10),
      const LinearProgressIndicator(),
      const SizedBox(height: 8),
      const Text('Di solito servono 2–6 minuti. Tieni l\'app aperta.',
          style: TextStyle(fontSize: 12, color: Colors.white54)),
    ]);
  }
}
