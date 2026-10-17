import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/project.dart';

/// Annulla / ripeti basato su istantanee JSON del progetto.
/// Ogni istantanea viene anche salvata su disco come "ultimo progetto".
class History {
  History(Project initial) : _states = [initial.encode()];

  final List<String> _states;
  int _index = 0;
  static const _max = 80;

  bool get canUndo => _index > 0;
  bool get canRedo => _index < _states.length - 1;

  /// Registra lo stato attuale dopo una modifica.
  void commit(Project p) {
    final s = p.encode();
    if (s == _states[_index]) return;
    _states.removeRange(_index + 1, _states.length);
    _states.add(s);
    if (_states.length > _max) _states.removeAt(0);
    _index = _states.length - 1;
    ProjectStore.save(s);
  }

  Project undo() {
    if (canUndo) _index--;
    ProjectStore.save(_states[_index]);
    return Project.decode(_states[_index]);
  }

  Project redo() {
    if (canRedo) _index++;
    ProjectStore.save(_states[_index]);
    return Project.decode(_states[_index]);
  }
}

/// Salvataggio automatico dell'ultimo progetto.
class ProjectStore {
  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'last_project.json'));
  }

  static Future<void> save(String json) async {
    try {
      await (await _file()).writeAsString(json, flush: true);
    } catch (_) {}
  }

  static Future<Project?> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      final project = Project.decode(await f.readAsString());
      // Scarta le clip i cui file non esistono più (cache svuotata).
      project.clips.removeWhere((c) => !File(c.path).existsSync());
      if (project.music != null && !File(project.music!.path).existsSync()) {
        project.music = null;
      }
      return project.clips.isEmpty ? null : project;
    } catch (_) {
      return null;
    }
  }
}
