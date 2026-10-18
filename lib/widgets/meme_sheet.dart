import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/project.dart';

/// Pannello "Meme": fasce sopra e sotto il video con il testo.
/// Modifica direttamente il progetto. Restituisce true se confermato.
Future<bool?> showMemeSheet(BuildContext context, Project p) {
  String textOf(String tag) =>
      p.overlays.where((o) => o.tag == tag).map((o) => o.text).firstOrNull ?? '';
  final top = TextEditingController(text: textOf('meme-top'));
  final bottom = TextEditingController(text: textOf('meme-bottom'));
  var upper = true;

  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFF1A1B20),
    builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
      final accent = Theme.of(ctx).colorScheme.primary;
      return Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('Meme', style: Theme.of(ctx).textTheme.titleLarge),
              const Spacer(),
              if (p.meme)
                TextButton.icon(
                  onPressed: () {
                    removeMeme(p);
                    Navigator.pop(ctx, true);
                  },
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('Togli meme'),
                ),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: top,
              maxLines: 3,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Testo sopra', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: bottom,
              maxLines: 3,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Testo sotto', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            Row(children: [
              const Text('Fasce'),
              const SizedBox(width: 12),
              ChoiceChip(
                label: const Text('Nere'),
                selected: !p.memeWhite,
                onSelected: (_) => setState(() => p.memeWhite = false),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Bianche'),
                selected: p.memeWhite,
                onSelected: (_) => setState(() => p.memeWhite = true),
              ),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('TUTTO MAIUSCOLO'),
              value: upper,
              onChanged: (v) => setState(() => upper = v),
            ),
            Text('Altezza fascia sopra ${(p.memeTop * 100).round()}%'),
            Slider(min: 0, max: 0.35, value: p.memeTop, onChanged: (v) => setState(() => p.memeTop = v)),
            Text('Altezza fascia sotto ${(p.memeBottom * 100).round()}%'),
            Slider(min: 0, max: 0.35, value: p.memeBottom, onChanged: (v) => setState(() => p.memeBottom = v)),
            const SizedBox(height: 4),
            Text('Formato attuale: ${p.aspect.label}. Per i meme vanno bene 1:1 e 4:5.',
                style: const TextStyle(fontSize: 12, color: Colors.white54)),
            const SizedBox(height: 4),
            Wrap(spacing: 8, children: [
              for (final a in AspectRatioPreset.values)
                ChoiceChip(
                  label: Text(a.label),
                  selected: p.aspect == a,
                  onSelected: (_) => setState(() => p.aspect = a),
                ),
            ]),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: accent),
                onPressed: () {
                  String fix(String t) => upper ? t.trim().toUpperCase() : t.trim();
                  applyMeme(p, fix(top.text), fix(bottom.text));
                  Navigator.pop(ctx, true);
                },
                icon: const Icon(Icons.check_rounded),
                label: const Text('Applica'),
              ),
            ),
          ]),
        ),
      );
    }),
  );
}

/// Attiva il meme e crea/aggiorna i due testi nelle fasce.
void applyMeme(Project p, String topText, String bottomText) {
  p.meme = true;
  final total = p.totalDuration;
  final h = p.aspect.height.toDouble(), w = p.aspect.width.toDouble();
  final textColor = p.memeWhite ? Colors.black : Colors.white;

  void upsert(String tag, String text, double band, double cy) {
    p.overlays.removeWhere((o) => o.tag == tag);
    if (text.isEmpty || band < 0.03) return;
    p.overlays.add(VideoOverlay(
      kind: OverlayKind.text,
      text: text,
      start: Duration.zero,
      end: total,
      color: textColor,
      fontSize: fitMemeFont(text, w, h * band),
      box: false,
      outline: false,
      cx: 0.5,
      cy: cy,
      animIn: AnimIn.none,
      animOut: AnimOut.none,
      tag: tag,
    ));
  }

  upsert('meme-top', topText, p.memeTop, p.memeTop / 2);
  upsert('meme-bottom', bottomText, p.memeBottom, 1 - p.memeBottom / 2);
}

void removeMeme(Project p) {
  p.meme = false;
  p.overlays.removeWhere((o) => o.isMeme);
}

/// Dimensione del carattere più grande che fa stare [text] nella fascia
/// (stima: un carattere in grassetto è largo circa 0,58 volte la sua altezza).
double fitMemeFont(String text, double width, double bandHeight) {
  final maxW = width * 0.88;
  final words = text.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  for (var f = math.min(130.0, bandHeight * 0.6); f > 24; f -= 2) {
    final charW = f * 0.58;
    var lines = 1;
    var line = 0.0;
    for (final word in words) {
      final ww = word.length * charW;
      final add = line == 0 ? ww : ww + charW;
      if (line + add > maxW && line > 0) {
        lines++;
        line = ww;
      } else {
        line += add;
      }
    }
    if (lines * f * 1.15 <= bandHeight * 0.86) return f;
  }
  return 24;
}
