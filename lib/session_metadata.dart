import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

// ══════════════════════════════════════════════════════════════════════════
//  Sidecar metadata (custom name + notes + material) per CSV recording.
//
//  Stored as a single JSON file in the app documents directory:
//    {
//      "CAPNO_xxx.csv": {
//        "name":     "...",
//        "notes":    "...",
//        "material": "...",   // formatted text block, scanned from QR
//      },
//      ...
//    }
//
//  Keyed by CSV filename. When a CSV is deleted or renamed, the sidecar
//  entry is removed or renamed in sync.
// ══════════════════════════════════════════════════════════════════════════
class SessionMetadata {
  SessionMetadata._();
  static final SessionMetadata instance = SessionMetadata._();

  static const _fileName = 'session_metadata.json';
  Map<String, Map<String, String>> _store = {};
  bool _loaded = false;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    try {
      final f = await _file();
      if (await f.exists()) {
        final raw = await f.readAsString();
        final json = jsonDecode(raw) as Map<String, dynamic>;
        _store = json.map(
          (k, v) => MapEntry(k, Map<String, String>.from(v as Map)),
        );
      }
    } catch (e) {
      debugPrint('[Meta] load error: $e');
    }
    _loaded = true;
  }

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(_store));
    } catch (e) {
      debugPrint('[Meta] save error: $e');
    }
  }

  // ── Public API ────────────────────────────────────────────────────────
  Future<String> getName(String csvFilename) async {
    await _ensureLoaded();
    return _store[csvFilename]?['name'] ?? '';
  }

  Future<String> getNotes(String csvFilename) async {
    await _ensureLoaded();
    return _store[csvFilename]?['notes'] ?? '';
  }

  Future<String> getMaterial(String csvFilename) async {
    await _ensureLoaded();
    return _store[csvFilename]?['material'] ?? '';
  }

  Future<void> setName(String csvFilename, String name) async {
    await _ensureLoaded();
    final entry = _store[csvFilename] ?? <String, String>{};
    entry['name'] = name;
    _store[csvFilename] = entry;
    await _save();
  }

  Future<void> setNotes(String csvFilename, String notes) async {
    await _ensureLoaded();
    final entry = _store[csvFilename] ?? <String, String>{};
    entry['notes'] = notes;
    _store[csvFilename] = entry;
    await _save();
  }

  Future<void> setMaterial(String csvFilename, String material) async {
    await _ensureLoaded();
    final entry = _store[csvFilename] ?? <String, String>{};
    entry['material'] = material;
    _store[csvFilename] = entry;
    await _save();
  }

  Future<void> rename(String oldName, String newName) async {
    await _ensureLoaded();
    final entry = _store.remove(oldName);
    if (entry != null) {
      _store[newName] = entry;
      await _save();
    }
  }

  Future<void> remove(String csvFilename) async {
    await _ensureLoaded();
    if (_store.remove(csvFilename) != null) await _save();
  }
}
