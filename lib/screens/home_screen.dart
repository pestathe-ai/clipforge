import 'package:flutter/material.dart';

import '../models/project.dart';
import 'editor_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Icon(Icons.movie_filter_rounded,
                  size: 56, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('ClipForge',
                  style: theme.textTheme.displaySmall
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(
                'Taglia, unisci, aggiungi testi, filtri e musica. '
                'Tutto sul telefono, tutto open source.',
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: Colors.white70),
              ),
              const Spacer(),
              Text('Nuovo progetto', style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final a in AspectRatioPreset.values)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _AspectCard(preset: a),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _AspectCard extends StatelessWidget {
  const _AspectCard({required this.preset});
  final AspectRatioPreset preset;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        final project = Project()..aspect = preset;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => EditorScreen(project: project)),
        );
      },
      child: Ink(
        height: 120,
        decoration: BoxDecoration(
          color: const Color(0xFF1C1D22),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              height: 48,
              child: AspectRatio(
                aspectRatio: preset.ratio,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: color, width: 2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(preset.label,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
