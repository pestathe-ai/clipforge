import 'package:flutter/material.dart';

import '../models/project.dart';
import '../services/subtitle_service.dart';

const _languages = {
  'it': 'Italiano',
  'en': 'Inglese',
  'es': 'Spagnolo',
  'fr': 'Francese',
  'de': 'Tedesco',
  'pt': 'Portoghese',
};

/// Pannello "Sottotitoli automatici": scarica il modello (una volta),
/// trascrive l'audio e restituisce i sottotitoli generati.
Future<List<VideoOverlay>?> showSubtitleSheet(
    BuildContext context, Project project, SubtitleService service) {
  return showModalBottomSheet<List<VideoOverlay>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    isDismissible: false,
    backgroundColor: const Color(0xFF1A1B20),
    builder: (_) => _SubtitleSheet(project: project, service: service),
  );
}

class _SubtitleSheet extends StatefulWidget {
  const _SubtitleSheet({required this.project, required this.service});
  final Project project;
  final SubtitleService service;

  @override
  State<_SubtitleSheet> createState() => _SubtitleSheetState();
}

class _SubtitleSheetState extends State<_SubtitleSheet> {
  WhisperSize _model = WhisperSize.base;
  String _lang = 'it';
  bool _busy = false;
  double? _progress;
  String _phase = '';
  String? _error;
  final _ready = <WhisperSize, bool>{};

  @override
  void initState() {
    super.initState();
    for (final m in WhisperSize.values) {
      widget.service.isDownloaded(m).then((v) {
        if (mounted) setState(() => _ready[m] = v);
      });
    }
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_ready[_model] != true) {
        setState(() => _phase = 'Scarico il modello (solo la prima volta)…');
        await widget.service.download(_model, (v) {
          if (mounted) setState(() => _progress = v);
        });
        _ready[_model] = true;
      }
      setState(() {
        _progress = null;
        _phase = 'Ascolto l\'audio…';
      });
      final subs = await widget.service.generate(
        widget.project,
        model: _model,
        language: _lang,
        onProgress: (phase, v) {
          if (mounted) {
            setState(() {
              _phase = 'Trascrivo: $phase';
              _progress = v;
            });
          }
        },
      );
      if (!mounted) return;
      if (subs.isEmpty) {
        setState(() {
          _busy = false;
          _error = 'Non ho trovato parlato nelle clip.';
        });
        return;
      }
      Navigator.pop(context, subs);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Errore: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasAudio = widget.project.clips.any((c) => c.hasAudio);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sottotitoli automatici', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          const Text(
            'Il riconoscimento vocale gira sul telefono, senza internet '
            '(serve solo per scaricare il modello la prima volta).',
            style: TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const SizedBox(height: 16),
          const Text('Lingua parlata', style: TextStyle(color: Colors.white60, fontSize: 12)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final e in _languages.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: _lang == e.key,
                onSelected: _busy ? null : (_) => setState(() => _lang = e.key),
              ),
          ]),
          const SizedBox(height: 14),
          const Text('Modello', style: TextStyle(color: Colors.white60, fontSize: 12)),
          for (final m in WhisperSize.values)
            RadioListTile<WhisperSize>(
              contentPadding: EdgeInsets.zero,
              value: m,
              groupValue: _model,
              onChanged: _busy ? null : (v) => setState(() => _model = v!),
              title: Text(m.label),
              subtitle: Text(_ready[m] == true ? 'Già scaricato' : 'Da scaricare: ${m.download}'),
            ),
          if (_busy) ...[
            const SizedBox(height: 8),
            Text(_phase),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _progress),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Color(0xFFFF6B6B))),
          ],
          const SizedBox(height: 16),
          Row(children: [
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('Annulla'),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _busy || !hasAudio ? null : _start,
              icon: const Icon(Icons.subtitles_rounded),
              label: Text(hasAudio ? 'Genera' : 'Nessun audio'),
            ),
          ]),
        ],
      ),
    );
  }
}
