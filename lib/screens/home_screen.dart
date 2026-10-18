import 'package:flutter/material.dart';

import '../models/project.dart';
import '../state/history.dart';
import 'editor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Project? _last;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final p = await ProjectStore.load();
    if (mounted) setState(() => _last = p);
  }

  Future<void> _open(Project p, {bool pick = true, bool meme = false}) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => EditorScreen(project: p, pickOnStart: pick, memeOnStart: meme)),
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final last = _last;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 24),
            Icon(Icons.movie_filter_rounded, size: 52, color: accent),
            const SizedBox(height: 12),
            Text('ClipForge',
                style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text('Editor video open source',
                style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white60)),
            const SizedBox(height: 32),

            // Nuovo progetto (grande, come CapCut).
            Material(
              color: accent,
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => _open(Project()),
                child: const SizedBox(
                  height: 110,
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.add_circle_rounded, size: 36, color: Colors.black),
                    SizedBox(width: 12),
                    Text('Nuovo progetto',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.black)),
                  ]),
                ),
              ),
            ),

            const SizedBox(height: 12),
            Material(
              color: const Color(0xFF1C1D22),
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => _open(Project(aspect: AspectRatioPreset.square), meme: true),
                child: const SizedBox(
                  height: 72,
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.sentiment_very_satisfied_rounded, size: 28),
                    SizedBox(width: 10),
                    Text('Crea meme', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                    SizedBox(width: 8),
                    Flexible(
                      child: Text('fasce sopra e sotto con il testo',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: Colors.white54)),
                    ),
                  ]),
                ),
              ),
            ),

            if (last != null) ...[
              const SizedBox(height: 28),
              Text('Riprendi', style: theme.textTheme.titleMedium),
              const SizedBox(height: 10),
              Material(
                color: const Color(0xFF1C1D22),
                borderRadius: BorderRadius.circular(14),
                child: ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  leading: const Icon(Icons.history_rounded),
                  title: const Text('Ultimo progetto'),
                  subtitle: Text('${last.clips.length} clip · ${_fmt(last.totalDuration)} · ${last.aspect.label}'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _open(last, pick: false),
                ),
              ),
            ],

            const SizedBox(height: 28),
            Text('Cosa puoi fare', style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            const Wrap(spacing: 8, runSpacing: 8, children: [
              _Feature(Icons.content_cut_rounded, 'Taglia e dividi'),
              _Feature(Icons.compare_arrows_rounded, '12 transizioni'),
              _Feature(Icons.auto_awesome_rounded, '10 effetti'),
              _Feature(Icons.filter_vintage_rounded, '9 filtri'),
              _Feature(Icons.title_rounded, 'Testi animati'),
              _Feature(Icons.emoji_emotions_rounded, 'Sticker'),
              _Feature(Icons.subtitles_rounded, 'Sottotitoli automatici'),
              _Feature(Icons.music_note_rounded, 'Musica'),
              _Feature(Icons.speed_rounded, 'Velocità'),
              _Feature(Icons.undo_rounded, 'Annulla / ripeti'),
              _Feature(Icons.photo_rounded, 'Foto'),
              _Feature(Icons.mic_rounded, 'Voce fuori campo'),
              _Feature(Icons.picture_in_picture_alt_rounded, 'Sovrapposizioni'),
              _Feature(Icons.format_color_reset_rounded, 'Green screen'),
              _Feature(Icons.interests_rounded, 'Maschere'),
              _Feature(Icons.moving_rounded, 'Keyframe'),
              _Feature(Icons.fast_rewind_rounded, 'Al contrario'),
              _Feature(Icons.record_voice_over_rounded, 'Effetti voce'),
              _Feature(Icons.dashboard_customize_rounded, '7 modelli'),
              _Feature(Icons.person_remove_rounded, 'Rimuovi sfondo IA'),
              _Feature(Icons.my_location_rounded, 'Tracciamento'),
              _Feature(Icons.show_chart_rounded, 'Curve di velocità'),
              _Feature(Icons.tune_rounded, 'Regolazioni colore'),
              _Feature(Icons.video_stable_rounded, 'Stabilizzazione'),
              _Feature(Icons.hd_rounded, 'Fino a 4K 60fps'),
            ]),
          ],
        ),
      ),
    );
  }

  static String _fmt(Duration d) =>
      '${d.inMinutes}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';
}

class _Feature extends StatelessWidget {
  const _Feature(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1D22),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ]),
    );
  }
}
