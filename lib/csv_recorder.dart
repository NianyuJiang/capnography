import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import 'backup_store.dart';
import 'ble_history_sync.dart';
import 'ble_manager.dart';
import 'device_names.dart';
import 'device_session.dart';
import 'session_metadata.dart';

// ══════════════════════════════════════════════════════════════════════════
//  Multi-session CSV recorder.
//
//  Each connected DeviceSession gets its own _RecordingState — independent
//  IOSink, row counter, start time, filename. Sessions don't interfere.
//
//  File naming:  CAPNO_<patient_or_devN>_<startYMD_HMS>__<endYMD_HMS>.csv
//
//  When a recording starts, we auto-populate session_metadata.json from
//  the QR-supplied dict:
//     title  ← device name (only when no title is set yet)
//     notes  ← formatted block: Device / Age / Note / Connected
// ══════════════════════════════════════════════════════════════════════════

class CsvRecorder {
  CsvRecorder._();
  static final CsvRecorder instance = CsvRecorder._();

  final Map<String, _RecState> _states = {}; // keyed by MAC
  StreamSubscription? _sampleSub;
  StreamSubscription? _sessionsSub;

  bool _initialized = false;

  // ── "Continue recording" requests (see connect_flow.dart) ─────────────
  final Map<String, File> _pendingResume = {}; // keyed by MAC / device id
  void markPendingResume(String mac, File previous) =>
      _pendingResume[mac] = previous;
  void clearPendingResume(String mac) => _pendingResume.remove(mac);

  /// Newest finished recording whose `mac,` header line equals [mac]
  /// (newest by its `start_iso,` header), or null.
  static Future<File?> mostRecentRecordingForMac(String mac) async {
    try {
      final dir = await _recordingsDir();
      File? best;
      DateTime? bestStart;
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.csv') || f.path.endsWith('__pending.csv')) {
          continue;
        }
        final head = await f
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .take(14)
            .toList();
        String? fileMac;
        DateTime? start;
        for (final l in head) {
          if (l.startsWith('mac,')) fileMac = l.substring(4).trim();
          if (l.startsWith('start_iso,')) {
            start = DateTime.tryParse(l.substring(10).trim());
          }
        }
        if (fileMac == mac &&
            start != null &&
            (bestStart == null || start.isAfter(bestStart))) {
          best = f;
          bestStart = start;
        }
      }
      return best;
    } catch (e) {
      debugPrint('[CSV] mostRecentRecordingForMac error: $e');
      return null;
    }
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────
  void init() {
    if (_initialized) return;
    _initialized = true;

    // Data-safety on startup: finalize any recording orphaned by a previous
    // crash/kill, and purge trash items past their 30-day retention.
    _recoverAndPurge();

    // Per-sample → write the right session's row
    _sampleSub = BleManager.instance.sampleStream.listen(_onSample);

    // Watch session add/remove to start & stop recordings automatically
    _sessionsSub =
        _seToStream().listen((sessions) => _reconcile(sessions));
  }

  // Adapt the ValueNotifier into a stream for the listener
  Stream<List<DeviceSession>> _seToStream() {
    final controller = StreamController<List<DeviceSession>>();
    final notifier = BleManager.instance.sessionsNotifier;
    void emit() => controller.add(notifier.value);
    notifier.addListener(emit);
    controller.onCancel = () => notifier.removeListener(emit);
    return controller.stream;
  }

  Future<void> _reconcile(List<DeviceSession> active) async {
    final activeMacs = active.map((s) => s.mac).toSet();

    // Start a recording for any new session
    for (final s in active) {
      if (!_states.containsKey(s.mac)) {
        await _start(s);
      }
    }
    // Stop recordings for sessions that are no longer active
    for (final mac in _states.keys.toList()) {
      if (!activeMacs.contains(mac)) {
        await _stop(mac);
      }
    }
  }

  // ── Start ─────────────────────────────────────────────────────────────
  Future<void> _start(DeviceSession session) async {
    // "No → Continue": reopen the device's last recording and backfill it.
    final resumeFile = _pendingResume.remove(session.mac);
    if (resumeFile != null && await resumeFile.exists()) {
      if (await _resume(session, resumeFile)) return;
      // Could not reopen it → fall through to a fresh recording.
    }
    try {
      final dir = await _recordingsDir();
      final now = DateTime.now();
      final patientSlug = _slug(session.patient ?? 'dev${session.slot}');

      // The device tag keeps concurrent sessions apart: two probes on the
      // SAME patient started in the same second would otherwise generate an
      // identical filename and the second would truncate the first.
      final prefix = 'CAPNO_${patientSlug}_${_macTag(session.mac)}';
      final pending =
          await _uniqueName(dir, prefix, '_${_stamp(now)}__pending.csv');
      final file = File('${dir.path}/$pending');
      await file.create(recursive: true); // exists before the next _start runs
      final sink = file.openWrite(mode: FileMode.write);

      sink.writeln('# Capnography Session');
      sink.writeln('mac,${session.mac}');
      sink.writeln('slot,${session.slot}');
      sink.writeln('start_iso,${now.toIso8601String()}');
      sink.writeln('end_iso,');
      // Embed QR meta as comments so the CSV is self-describing
      for (final key in const ['name', 'patient', 'age', 'note']) {
        final v = session.meta[key];
        if (v != null && v.toString().isNotEmpty) {
          sink.writeln('${key}_meta,$v');
        }
      }
      sink.writeln('---');
      sink.writeln('elapsed,co2_percent,mic_rms,breath_flag');

      _states[session.mac] = _RecState(
        session: session,
        file: file,
        sink: sink,
        startTime: now,
      );

      // Populate sidecar metadata (title + notes) from QR info
      await _populateSidecar(session, file, now);

      // Fresh recording: whatever the device stored while disconnected
      // belongs to the previous patient/session -- discard it.
      unawaited(BleHistorySync.clear(session.historyChar));

      debugPrint('[CSV] start ${session.mac} → ${file.path}');
    } catch (e) {
      debugPrint('[CSV] start failed for ${session.mac}: $e');
    }
  }

  Future<void> _populateSidecar(
      DeviceSession s, File csvFile, DateTime startedAt) async {
    final csvName = csvFile.uri.pathSegments.last;

    // Title = device name (e.g. "CO2-sensor-01") if provided.
    // Only fill it in when no title exists yet — never overwrite a name
    // the user has manually edited.
    final devName = (s.meta['name'] as String?)?.trim();
    if (devName != null && devName.isNotEmpty) {
      final existing = await SessionMetadata.instance.getName(csvName);
      if (existing.isEmpty) {
        await SessionMetadata.instance.setName(csvName, devName);
      }
    }

    // Notes — format A: labelled multi-line.
    // Notes are session-specific and shouldn't be merged with previous
    // content (this is a brand-new CSV), so it's safe to overwrite.
    final lines = <String>[];
    final noteDev = devName ?? '';
    if (noteDev.isNotEmpty) {
      lines.add('Device: $noteDev');
    } else if (bleNameOf(s.device).isNotEmpty) {
      lines.add('Device: ${bleNameOf(s.device)}');
    }
    final patient = (s.meta['patient'] as String?)?.trim();
    if (patient != null && patient.isNotEmpty) {
      lines.add('Patient: $patient');
    }
    final age = s.meta['age'];
    if (age != null && age.toString().isNotEmpty) {
      lines.add('Age: $age');
    }
    final note = (s.meta['note'] as String?)?.trim();
    if (note != null && note.isNotEmpty) {
      lines.add('Note: $note');
    }
    lines.add(
        'Connected: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(startedAt)}');

    if (lines.isNotEmpty) {
      await SessionMetadata.instance.setNotes(csvName, lines.join('\n'));
    }
  }


  // ── Resume ("No → Continue") ──────────────────────────────────────────
  /// Reopens [prev] as this session's recording (elapsed time keeps counting
  /// from its ORIGINAL start), then pulls the data the device stored in its
  /// own memory while the phone was away and writes it in first. Live rows
  /// that arrive meanwhile are held back so the file stays chronological.
  /// Returns false if the file could not be reopened.
  Future<bool> _resume(DeviceSession session, File prev) async {
    try {
      final oldName = prev.uri.pathSegments.last;
      final base = oldName.replaceAll('.csv', '');
      final pendingName = '${base.split('__').first}__pending.csv';
      final lines = await prev.readAsLines();

      DateTime? start;
      for (var i = 0; i < lines.length && i < 14; i++) {
        if (lines[i].startsWith('start_iso,')) {
          start = DateTime.tryParse(lines[i].substring(10).trim());
        } else if (lines[i].startsWith('end_iso,')) {
          lines[i] = 'end_iso,'; // reopened: open-ended again
        }
      }
      if (start == null) return false;
      await prev.writeAsString('${lines.join('\n')}\n');

      final file = await prev.rename('${prev.parent.path}/$pendingName');
      await SessionMetadata.instance.rename(oldName, pendingName);
      final sink = file.openWrite(mode: FileMode.append);
      final st = _RecState(
        session: session,
        file: file,
        sink: sink,
        startTime: start,
      )
        ..rowCount = 1 // existing file counts as non-empty
        ..backfilling = true;
      _states[session.mac] = st;
      debugPrint('[CSV] resume ${session.mac} → ${file.path}');

      unawaited(_backfill(st));
      return true;
    } catch (e) {
      debugPrint('[CSV] resume failed: $e');
      return false;
    }
  }

  Future<void> _backfill(_RecState st) async {
    var written = 0;
    try {
      final res = await BleHistorySync.sync(st.session.historyChar);
      if (res == null) {
        debugPrint('[CSV] backfill: device has no history buffer');
      } else if (res.records.isEmpty) {
        debugPrint('[CSV] backfill: nothing stored (${res.endReason})');
        if (res.complete) await BleHistorySync.clear(st.session.historyChar);
      } else if (res.anchorWall == null) {
        // Cannot date the records without the end marker: keep them on the
        // device so a later "Continue" can retry.
        debugPrint('[CSV] backfill: no end marker (${res.endReason}) — '
            '${res.records.length} record(s) NOT written');
      } else {
        for (final r in res.records) {
          final wall = res.wallTimeOf(r)!;
          final elapsed = wall.difference(st.startTime);
          if (elapsed.isNegative) continue;
          st.sink.writeln('${_fmtElapsed(elapsed)},'
              '${r.pco2.toStringAsFixed(4)},'
              '${r.rms.toStringAsFixed(2)},${r.breath ? 1 : 0}');
          st.rowCount++;
          written++;
        }
        await st.sink.flush();
        if (res.complete) await BleHistorySync.clear(st.session.historyChar);
        debugPrint('[CSV] backfill: wrote $written row(s) '
            '(device sent ${res.deviceSent}, dropped ${res.deviceDropped}, '
            'end: ${res.endReason})');
      }
    } catch (e) {
      debugPrint('[CSV] backfill error: $e');
    } finally {
      // Release the live rows that were held back during the sync.
      st.backfilling = false;
      try {
        for (final line in st.heldRows) {
          st.sink.writeln(line);
          st.rowCount++;
        }
        st.heldRows.clear();
        await st.sink.flush();
      } catch (e) {
        debugPrint('[CSV] flush held rows error: $e');
      }
    }
  }

  static String _fmtElapsed(Duration e) {
    final h = e.inHours.toString().padLeft(2, '0');
    final m = (e.inMinutes % 60).toString().padLeft(2, '0');
    final s = (e.inSeconds % 60).toString().padLeft(2, '0');
    final ms = (e.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  // ── Per-sample write ──────────────────────────────────────────────────
  void _onSample(SampleEvent ev) {
    final st = _states[ev.session.mac];
    if (st == null) return;
    final elapsed = DateTime.now().difference(st.startTime);
    final line = '${_fmtElapsed(elapsed)},${ev.co2.toStringAsFixed(4)},'
        '${ev.rms.toStringAsFixed(2)},${ev.breath ? 1 : 0}';
    if (st.backfilling) {
      st.heldRows.add(line); // written right after the backfill, in order
      return;
    }
    try {
      st.sink.writeln(line);
      st.rowCount++;
      // Flush EVERY row: samples arrive ~30 s apart, so the cost is trivial
      // and it guarantees data is on disk even if the app is killed/crashes.
      st.sink.flush();
    } catch (e) {
      debugPrint('[CSV] write error for ${ev.session.mac}: $e');
    }
  }

  // ── Stop ──────────────────────────────────────────────────────────────
  Future<void> _stop(String mac) async {
    final st = _states.remove(mac);
    if (st == null) return;
    final endTime = DateTime.now();

    try {
      await st.sink.flush();
      await st.sink.close();
    } catch (_) {}

    // Drop empty files
    if (st.rowCount == 0) {
      try {
        await st.file.delete();
      } catch (_) {}
      debugPrint('[CSV] empty session discarded: $mac');
      return;
    }

    // Rename to include the end timestamp; keep sidecar metadata in sync.
    // Same device tag + uniqueness check as _start, so finishing two
    // concurrent sessions can never overwrite one another.
    final oldName = st.file.uri.pathSegments.last;
    final patientSlug =
        _slug(st.session.patient ?? 'dev${st.session.slot}');
    final prefix = 'CAPNO_${patientSlug}_${_macTag(mac)}';
    final newName = await _uniqueName(
        st.file.parent, prefix, '_${_stamp(st.startTime)}__${_stamp(endTime)}.csv');
    try {
      final renamed = await st.file.rename('${st.file.parent.path}/$newName');
      await _patchEndIso(renamed, endTime);
      await SessionMetadata.instance.rename(oldName, newName);
      debugPrint('[CSV] saved: $newName');
      await _mirrorToPublic(renamed);
    } catch (e) {
      debugPrint('[CSV] rename error: $e');
    }
  }

  /// Best-effort mirror of a FINISHED recording into public device storage
  /// (Documents/<app folder>/) so the data survives an app uninstall.
  ///
  /// Deliberately fire-and-forget in spirit: it never throws, and a failure
  /// (no permission yet, no shared storage, full disk) is logged and
  /// ignored — the private copy in app storage is still authoritative.
  static Future<void> _mirrorToPublic(File csv) async {
    try {
      final saved = await BackupStore.saveCopy(csv);
      debugPrint(saved == null
          ? '[CSV] public mirror skipped: ${csv.uri.pathSegments.last}'
          : '[CSV] public mirror ok: ${saved.path}');
    } catch (e) {
      debugPrint('[CSV] public mirror error: $e');
    }
  }

  static Future<void> _patchEndIso(File f, DateTime end) async {
    try {
      final lines = await f.readAsLines();
      for (var i = 0; i < lines.length && i < 12; i++) {
        if (lines[i].startsWith('end_iso,')) {
          lines[i] = 'end_iso,${end.toIso8601String()}';
          break;
        }
      }
      await f.writeAsString('${lines.join('\n')}\n');
    } catch (_) {}
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  /// Last 4 hex digits of the MAC — a short per-device token that makes a
  /// filename unique even when several sensors share a patient name and
  /// start/stop in the same second.
  static String _macTag(String mac) {
    final hex = mac.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    final tail = hex.length >= 4 ? hex.substring(hex.length - 4) : hex;
    return tail.toUpperCase();
  }

  /// `<prefix><suffix>`, disambiguated with `-2`, `-3`… if it already exists.
  ///
  /// The counter is appended to the PREFIX (never to the timestamps), so the
  /// start stamp stays the final 15 characters before `__` and
  /// [RecordingInfo._parseTimes] keeps working.
  static Future<String> _uniqueName(
      Directory dir, String prefix, String suffix) async {
    var name = '$prefix$suffix';
    var n = 2;
    while (await File('${dir.path}/$name').exists()) {
      name = '$prefix-$n$suffix';
      n++;
    }
    return name;
  }

  static String _slug(String s) {
    final cleaned =
        s.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_').replaceAll(RegExp(r'_+'), '_');
    final trimmed = cleaned.replaceAll(RegExp(r'^_+|_+$'), '');
    return trimmed.isEmpty ? 'session' : trimmed;
  }

  static String _stamp(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}'
      '${dt.month.toString().padLeft(2, '0')}'
      '${dt.day.toString().padLeft(2, '0')}_'
      '${dt.hour.toString().padLeft(2, '0')}'
      '${dt.minute.toString().padLeft(2, '0')}'
      '${dt.second.toString().padLeft(2, '0')}';

  static Future<Directory> _recordingsDir() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}/capnography_records');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  // ── Public API for History page ───────────────────────────────────────
  static Future<List<RecordingInfo>> listRecordings() async {
    try {
      final dir = await _recordingsDir();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.csv'))
          .where((f) => !f.path.endsWith('__pending.csv'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      return files.map((f) => RecordingInfo.fromFile(f)).toList();
    } catch (e) {
      debugPrint('[CSV] listRecordings error: $e');
      return [];
    }
  }

  static Future<void> deleteFile(File f) async {
    try {
      final name = f.uri.pathSegments.last;
      await f.delete();
      await SessionMetadata.instance.remove(name);
    } catch (e) {
      debugPrint('[CSV] delete error: $e');
    }
  }

  static Future<RecordingData> parseFile(File f) async {
    try {
      final lines = await f.readAsLines();
      DateTime? start, end;
      final samples = <CsvSample>[];
      var inData = false;
      for (final line in lines) {
        if (line.startsWith('start_iso,')) {
          start = DateTime.tryParse(line.substring(10).trim());
        } else if (line.startsWith('end_iso,')) {
          end = DateTime.tryParse(line.substring(8).trim());
        } else if (line.trim() == '---') {
          inData = false;
        } else if (line.startsWith('elapsed,')) {
          inData = true;
        } else if (inData) {
          final parts = line.split(',');
          if (parts.length < 2) continue;
          final co2 = double.tryParse(parts[1]);
          if (co2 == null) continue;
          samples.add(CsvSample(
            elapsedText: parts[0],
            co2: co2,
            rms: parts.length > 2 ? double.tryParse(parts[2]) : null,
            breath: parts.length > 3 ? parts[3].trim() == '1' : null,
          ));
        }
      }
      return RecordingData(start: start, end: end, samples: samples);
    } catch (e) {
      debugPrint('[CSV] parse error: $e');
      return const RecordingData(start: null, end: null, samples: []);
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  DATA-SAFETY: crash recovery
  // ══════════════════════════════════════════════════════════════════════
  Future<void> _recoverAndPurge() async {
    await recoverPending();
    await purgeExpiredTrash();
  }

  /// Finalize any `*__pending.csv` left behind by a crash/kill so its data
  /// shows up in history instead of staying hidden. End time = file mtime.
  static Future<void> recoverPending() async {
    try {
      final dir = await _recordingsDir();
      final pendings = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('__pending.csv'))
          .toList();
      for (final f in pendings) {
        try {
          final oldName = f.uri.pathSegments.last;
          final lines = await f.readAsLines();
          final dataStart = lines.indexWhere((l) => l.startsWith('elapsed,'));
          final hasData = dataStart >= 0 && lines.length > dataStart + 1;
          if (!hasData) {
            await f.delete();
            await SessionMetadata.instance.remove(oldName);
            continue;
          }
          final end = f.statSync().modified;
          final base = oldName.replaceAll('.csv', '');
          final left = base.split('__').first; // <prefix>_<slug>_<startStamp>
          final newName = '${left}__${_stamp(end)}.csv';
          await _patchEndIso(f, end);
          final recovered = await f.rename('${f.parent.path}/$newName');
          await SessionMetadata.instance.rename(oldName, newName);
          debugPrint('[CSV] recovered orphaned recording → $newName');
          await _mirrorToPublic(recovered);
        } catch (e) {
          debugPrint('[CSV] recover failed for ${f.path}: $e');
        }
      }
    } catch (e) {
      debugPrint('[CSV] recoverPending error: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  TRASH (soft-delete, 30-day retention — like Apple Photos)
  // ══════════════════════════════════════════════════════════════════════
  static const int kTrashRetentionDays = 30;

  static Future<Directory> _trashDir() async {
    final root = await _recordingsDir();
    final dir = Directory('${root.path}/trash');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Soft-delete: move [f] into trash/ (kept [kTrashRetentionDays] days).
  /// The sidecar metadata (name/notes/material) follows the file.
  static Future<void> moveToTrash(File f) async {
    try {
      final trash = await _trashDir();
      final orig = f.uri.pathSegments.last;
      final trashName = 'DEL_${_stamp(DateTime.now())}__$orig';
      await f.rename('${trash.path}/$trashName');
      await SessionMetadata.instance.rename(orig, trashName);
      debugPrint('[CSV] moved to trash: $orig');
    } catch (e) {
      debugPrint('[CSV] moveToTrash error: $e');
    }
  }

  /// List trashed recordings (newest deletion first). Purges expired first.
  static Future<List<TrashedRecording>> listTrash() async {
    await purgeExpiredTrash();
    try {
      final trash = await _trashDir();
      final out = <TrashedRecording>[];
      for (final f in trash.listSync().whereType<File>()) {
        if (!f.path.endsWith('.csv')) continue;
        final t = TrashedRecording.fromFile(f);
        if (t != null) out.add(t);
      }
      out.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
      return out;
    } catch (e) {
      debugPrint('[CSV] listTrash error: $e');
      return [];
    }
  }

  /// Restore a trashed file back into the library.
  static Future<void> restoreFromTrash(File trashedFile) async {
    try {
      final records = await _recordingsDir();
      final trashName = trashedFile.uri.pathSegments.last;
      final original = TrashedRecording._stripPrefix(trashName) ?? trashName;
      var targetName = original;
      if (await File('${records.path}/$targetName').exists()) {
        targetName = '${original.replaceAll('.csv', '')}_restored.csv';
      }
      await trashedFile.rename('${records.path}/$targetName');
      await SessionMetadata.instance.rename(trashName, targetName);
      debugPrint('[CSV] restored: $targetName');
    } catch (e) {
      debugPrint('[CSV] restore error: $e');
    }
  }

  /// Permanently (hard) delete one trashed file.
  static Future<void> permanentlyDelete(File trashedFile) async {
    try {
      final name = trashedFile.uri.pathSegments.last;
      await trashedFile.delete();
      await SessionMetadata.instance.remove(name);
    } catch (e) {
      debugPrint('[CSV] permanentlyDelete error: $e');
    }
  }

  /// Hard-delete everything currently in the trash.
  static Future<void> emptyTrash() async {
    try {
      final trash = await _trashDir();
      for (final f in trash.listSync().whereType<File>()) {
        try {
          await SessionMetadata.instance.remove(f.uri.pathSegments.last);
          await f.delete();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[CSV] emptyTrash error: $e');
    }
  }

  /// Purge trashed items older than [kTrashRetentionDays].
  static Future<void> purgeExpiredTrash() async {
    try {
      final trash = await _trashDir();
      final now = DateTime.now();
      for (final f in trash.listSync().whereType<File>()) {
        final t = TrashedRecording.fromFile(f);
        if (t == null) continue;
        if (now.difference(t.deletedAt).inDays >= kTrashRetentionDays) {
          try {
            await SessionMetadata.instance.remove(f.uri.pathSegments.last);
            await f.delete();
            debugPrint('[CSV] purged expired trash: ${f.path}');
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[CSV] purgeExpiredTrash error: $e');
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _RecState {
  final DeviceSession session;
  final File file;
  final IOSink sink;
  final DateTime startTime;
  int rowCount = 0;
  bool backfilling = false;
  final List<String> heldRows = [];
  _RecState({
    required this.session,
    required this.file,
    required this.sink,
    required this.startTime,
  });
}

// ══════════════════════════════════════════════════════════════════════════
//  Value types used by the History page
// ══════════════════════════════════════════════════════════════════════════
class RecordingInfo {
  final File file;
  final String name;
  final int sizeBytes;
  final DateTime modified;
  final DateTime? startTime;
  final DateTime? endTime;

  RecordingInfo({
    required this.file,
    required this.name,
    required this.sizeBytes,
    required this.modified,
    required this.startTime,
    required this.endTime,
  });

  factory RecordingInfo.fromFile(File f) {
    final stat = f.statSync();
    final name = f.uri.pathSegments.last;
    final (start, end) = _parseTimes(name);
    return RecordingInfo(
      file: f,
      name: name,
      sizeBytes: stat.size,
      modified: stat.modified,
      startTime: start,
      endTime: end,
    );
  }

  // Parses filenames CAPNO_<slug>_YYYYMMDD_HHMMSS__YYYYMMDD_HHMMSS.csv
  static (DateTime?, DateTime?) _parseTimes(String filename) {
    try {
      final base = filename.replaceAll('.csv', '');
      if (!base.startsWith('CAPNO_')) return (null, null);
      // Split off the time stamps from the right (they are fixed-width)
      final parts = base.split('__');
      if (parts.length != 2) return (null, null);
      final left = parts[0]; // CAPNO_<slug>_<startStamp>
      final endStamp = parts[1];
      // Start stamp is the last 15 chars of `left`
      if (left.length < 16) return (null, null);
      final startStamp = left.substring(left.length - 15);
      return (_parseStamp(startStamp), _parseStamp(endStamp));
    } catch (_) {
      return (null, null);
    }
  }

  static DateTime? _parseStamp(String s) {
    // YYYYMMDD_HHMMSS
    if (s.length != 15 || s[8] != '_') return null;
    try {
      return DateTime(
        int.parse(s.substring(0, 4)),
        int.parse(s.substring(4, 6)),
        int.parse(s.substring(6, 8)),
        int.parse(s.substring(9, 11)),
        int.parse(s.substring(11, 13)),
        int.parse(s.substring(13, 15)),
      );
    } catch (_) {
      return null;
    }
  }

  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class CsvSample {
  final String elapsedText;
  final double co2;
  final double? rms; // null in old 2-column files
  final bool? breath;
  const CsvSample(
      {required this.elapsedText, required this.co2, this.rms, this.breath});
}

class RecordingData {
  final DateTime? start;
  final DateTime? end;
  final List<CsvSample> samples;
  const RecordingData(
      {required this.start, required this.end, required this.samples});

  double get peak => samples.isEmpty
      ? 0
      : samples.map((s) => s.co2).reduce((a, b) => a > b ? a : b);
  double get mean => samples.isEmpty
      ? 0
      : samples.map((s) => s.co2).reduce((a, b) => a + b) / samples.length;
  Duration? get duration =>
      (start != null && end != null) ? end!.difference(start!) : null;
}

// ══════════════════════════════════════════════════════════════════════════
//  A recording currently sitting in the trash (soft-deleted).
//  Filename scheme inside trash/:  DEL_<YYYYMMDD_HHMMSS>__<originalName>
// ══════════════════════════════════════════════════════════════════════════
class TrashedRecording {
  final File file; // the file inside trash/
  final String originalName; // e.g. CAPNO_..._....csv (as it will be restored)
  final DateTime deletedAt;
  final int sizeBytes;
  final DateTime? startTime;
  final DateTime? endTime;

  TrashedRecording({
    required this.file,
    required this.originalName,
    required this.deletedAt,
    required this.sizeBytes,
    required this.startTime,
    required this.endTime,
  });

  /// Strip the `DEL_<stamp>__` prefix → the original filename.
  static String? _stripPrefix(String trashName) {
    if (!trashName.startsWith('DEL_')) return null;
    final idx = trashName.indexOf('__');
    if (idx < 0) return null;
    return trashName.substring(idx + 2);
  }

  static DateTime? _parseDeletedStamp(String trashName) {
    if (!trashName.startsWith('DEL_')) return null;
    final idx = trashName.indexOf('__');
    if (idx < 0) return null;
    return RecordingInfo._parseStamp(trashName.substring(4, idx));
  }

  static TrashedRecording? fromFile(File f) {
    try {
      final name = f.uri.pathSegments.last;
      final original = _stripPrefix(name);
      final deletedAt = _parseDeletedStamp(name);
      if (original == null || deletedAt == null) return null;
      final stat = f.statSync();
      final (start, end) = RecordingInfo._parseTimes(original);
      return TrashedRecording(
        file: f,
        originalName: original,
        deletedAt: deletedAt,
        sizeBytes: stat.size,
        startTime: start,
        endTime: end,
      );
    } catch (_) {
      return null;
    }
  }

  /// Days remaining before auto-purge (0..30).
  int get daysLeft {
    final d = CsvRecorder.kTrashRetentionDays -
        DateTime.now().difference(deletedAt).inDays;
    return d < 0 ? 0 : d;
  }

  /// Trash filename (used as the SessionMetadata key while trashed).
  String get trashName => file.uri.pathSegments.last;

  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
