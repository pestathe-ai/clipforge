import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Registra la voce fuori campo mentre il video scorre.
/// Restituisce il percorso del file registrato, o null.
Future<String?> showVoiceSheet(
  BuildContext context, {
  required Future<void> Function() onStart,
  required Future<void> Function() onStop,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: const Color(0xFF1A1B20),
    builder: (_) => _VoiceSheet(onStart: onStart, onStop: onStop),
  );
}

class _VoiceSheet extends StatefulWidget {
  const _VoiceSheet({required this.onStart, required this.onStop});
  final Future<void> Function() onStart;
  final Future<void> Function() onStop;

  @override
  State<_VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<_VoiceSheet> {
  final _rec = AudioRecorder();
  bool _recording = false;
  String? _error;
  final _watch = Stopwatch();
  Timer? _timer;
  double _level = 0;
  StreamSubscription<Amplitude>? _amp;

  @override
  void dispose() {
    _timer?.cancel();
    _amp?.cancel();
    _rec.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      if (!await _rec.hasPermission()) {
        setState(() => _error = 'Serve il permesso del microfono.');
        return;
      }
      final docs = await getApplicationDocumentsDirectory();
      final path = p.join(docs.path, 'media', 'voce_${DateTime.now().millisecondsSinceEpoch}.m4a');
      await Directory(p.dirname(path)).create(recursive: true);
      await _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 44100, bitRate: 128000),
          path: path);
      await widget.onStart();
      _watch
        ..reset()
        ..start();
      _timer = Timer.periodic(const Duration(milliseconds: 200), (_) => setState(() {}));
      _amp = _rec.onAmplitudeChanged(const Duration(milliseconds: 120)).listen((a) {
        setState(() => _level = ((a.current + 50) / 50).clamp(0.0, 1.0));
      });
      setState(() => _recording = true);
    } catch (e) {
      setState(() => _error = 'Impossibile registrare: $e');
    }
  }

  Future<void> _stop() async {
    _timer?.cancel();
    await _amp?.cancel();
    _watch.stop();
    final path = await _rec.stop();
    await widget.onStop();
    if (mounted) Navigator.pop(context, path);
  }

  @override
  Widget build(BuildContext context) {
    final s = _watch.elapsed;
    final time = '${s.inMinutes}:${(s.inSeconds % 60).toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('Voce fuori campo', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(
          _recording
              ? 'Sto registrando… il video scorre mentre parli.'
              : 'La registrazione parte dalla posizione della testina.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white60),
        ),
        const SizedBox(height: 20),
        Text(time, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        SizedBox(
          width: 200,
          child: LinearProgressIndicator(value: _recording ? _level : 0, minHeight: 6),
        ),
        const SizedBox(height: 20),
        GestureDetector(
          onTap: _recording ? _stop : _start,
          child: Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 4),
            ),
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: _recording ? 30 : 62,
                height: _recording ? 30 : 62,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF3B5C),
                  borderRadius: BorderRadius.circular(_recording ? 6 : 31),
                ),
              ),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Color(0xFFFF6B6B))),
        ],
        const SizedBox(height: 12),
        if (!_recording)
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annulla')),
      ]),
    );
  }
}
