import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Risposta HTTP minima (per poter simulare la rete nei test).
class HttpReply {
  const HttpReply(this.status, this.body);
  final int status;
  final String body;
  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;
}

typedef HttpSend = Future<HttpReply> Function(
    String method, Uri url, Map<String, String> headers, List<int>? body);

class HiggsfieldException implements Exception {
  HiggsfieldException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum JobState { queued, inProgress, completed, failed, nsfw, canceled }

class JobStatus {
  const JobStatus(this.state, {this.videoUrl, this.error});
  final JobState state;
  final String? videoUrl;
  final String? error;
  bool get done => state != JobState.queued && state != JobState.inProgress;

  static JobStatus parse(Map<String, dynamic> j) {
    final s = (j['status'] as String? ?? '').toLowerCase();
    final state = switch (s) {
      'queued' => JobState.queued,
      'in_progress' => JobState.inProgress,
      'completed' => JobState.completed,
      'nsfw' => JobState.nsfw,
      'canceled' || 'cancelled' => JobState.canceled,
      _ => JobState.failed,
    };
    String? url;
    final v = j['video'];
    if (v is Map && v['url'] is String) url = v['url'] as String;
    if (url == null && j['videos'] is List && (j['videos'] as List).isNotEmpty) {
      final first = (j['videos'] as List).first;
      if (first is Map && first['url'] is String) url = first['url'] as String;
    }
    return JobStatus(state, videoUrl: url, error: j['error']?.toString() ?? j['detail']?.toString());
  }
}

/// Client minimo per l'API di Higgsfield (https://api.higgsfield.ai).
/// Protocollo come nel client ufficiale `higgsfield-client`:
/// - Authorization: `Key KEY_ID:KEY_SECRET`
/// - upload: POST /files/generate-upload-url → PUT su upload_url → public_url
/// - submit: POST /{modello} → request_id + status_url
/// - stato: GET status_url → status (+ video.url quando completed)
class HiggsfieldClient {
  HiggsfieldClient(this.credentials, {HttpSend? send}) : _send = send ?? _defaultSend;

  final String credentials;
  final HttpSend _send;
  static const base = 'https://api.higgsfield.ai';

  Map<String, String> get _auth => {
        'Authorization': 'Key ${credentials.trim()}',
        'Content-Type': 'application/json',
        'User-Agent': 'ClipForge',
      };

  Future<Map<String, dynamic>> _json(String method, String url, [Object? body]) async {
    final r = await _send(method, Uri.parse(url.startsWith('http') ? url : '$base$url'), _auth,
        body == null ? null : utf8.encode(jsonEncode(body)));
    if (r.status == 401 || r.status == 403) {
      throw HiggsfieldException('Chiave API non valida o senza credito (errore ${r.status}).');
    }
    if (r.status == 402) throw HiggsfieldException('Credito API esaurito: ricarica il saldo su Higgsfield.');
    if (r.status >= 400) throw HiggsfieldException('Errore Higgsfield ${r.status}: ${_short(r.body)}');
    return r.json;
  }

  /// Carica un file e restituisce l'URL pubblico da usare come image_url.
  Future<String> upload(String path, String contentType) async {
    final u = await _json('POST', '/files/generate-upload-url', {'content_type': contentType});
    final headers = <String, String>{'Content-Type': contentType};
    final extra = u['upload_headers'];
    if (extra is Map) headers.addAll(extra.map((k, v) => MapEntry('$k', '$v')));
    final r = await _send('PUT', Uri.parse(u['upload_url'] as String), headers, await File(path).readAsBytes());
    if (r.status >= 300) throw HiggsfieldException('Caricamento foto fallito (${r.status}).');
    return u['public_url'] as String;
  }

  /// Avvia una generazione e restituisce l'URL di stato.
  Future<String> submit(String model, Map<String, dynamic> args) async {
    final r = await _json('POST', '/$model', args);
    final url = r['status_url'] as String? ??
        (r['request_id'] != null ? '$base/requests/${r['request_id']}/status' : null);
    if (url == null) throw HiggsfieldException('Risposta inattesa da Higgsfield.');
    return url;
  }

  Future<JobStatus> status(String statusUrl) async => JobStatus.parse(await _json('GET', statusUrl));

  /// Attende la fine (polling) e restituisce l'URL del video.
  Future<String> wait(String statusUrl,
      {void Function(JobState)? onState, bool Function()? cancelled, Duration every = const Duration(seconds: 6)}) async {
    final deadline = DateTime.now().add(const Duration(minutes: 20));
    while (true) {
      if (cancelled?.call() ?? false) throw HiggsfieldException('Annullato.');
      final s = await status(statusUrl);
      onState?.call(s.state);
      if (s.done) {
        if (s.state == JobState.completed && s.videoUrl != null) return s.videoUrl!;
        if (s.state == JobState.nsfw) throw HiggsfieldException('La ripresa è stata bloccata dai filtri di Higgsfield.');
        throw HiggsfieldException('Generazione non riuscita${s.error != null ? ': ${s.error}' : ''}.');
      }
      if (DateTime.now().isAfter(deadline)) throw HiggsfieldException('Tempo scaduto.');
      await Future<void>.delayed(every);
    }
  }

  static String _short(String s) => s.length > 200 ? '${s.substring(0, 200)}…' : s;

  static Future<HttpReply> _defaultSend(
      String method, Uri url, Map<String, String> headers, List<int>? body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client.openUrl(method, url);
      headers.forEach(req.headers.set);
      if (body != null) {
        req.contentLength = body.length;
        req.add(body);
      }
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      return HttpReply(res.statusCode, text);
    } finally {
      client.close();
    }
  }
}

/// Scarica un file da [url] in [path].
Future<void> downloadTo(String url, String path) async {
  final client = HttpClient();
  try {
    final res = await (await client.getUrl(Uri.parse(url))).close();
    if (res.statusCode != 200) throw HiggsfieldException('Download fallito (${res.statusCode}).');
    await res.pipe(File(path).openWrite());
  } finally {
    client.close();
  }
}

/// Chiave salvata sul telefono (formato KEY_ID:KEY_SECRET).
class HiggsfieldKeyStore {
  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'higgsfield.key'));
  }

  static Future<String?> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      final k = (await f.readAsString()).trim();
      return k.isEmpty ? null : k;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String key) async => (await _file()).writeAsString(key.trim(), flush: true);
  static Future<void> clear() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
}
