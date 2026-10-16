import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ble_manager.dart';
import 'csv_recorder.dart';
import 'device_info.dart';
import 'device_session.dart';

// ══════════════════════════════════════════════════════════════════════════
//  device_health.dart — while a device is connected, reads its info
//  characteristic (device_info.dart) once at connect and then every 30 s:
//
//   • the latest values go to `session.info` (the detail page shows them);
//   • the device's power/connection EVENTS that this phone has not logged
//     yet (restart + reset cause, link closed + reason, history sent …) are
//     appended, with their real wall-clock time, to the recording's notes;
//   • a status line is written once per connection, and a warning line
//     whenever the flash-error / notify-error counters grow.
//
//  Started once from main(); does nothing for firmware without the
//  characteristic.
// ══════════════════════════════════════════════════════════════════════════
class DeviceHealth {
  DeviceHealth._();
  static final DeviceHealth instance = DeviceHealth._();

  static const Duration _period = Duration(seconds: 30);
  final Map<String, _Poller> _pollers = {};

  void init() {
    BleManager.instance.sessionsNotifier.addListener(_onSessions);
  }

  void _onSessions() {
    final sessions = BleManager.instance.sessionsNotifier.value;
    final live = <String>{};
    for (final s in sessions) {
      live.add(s.mac);
      final p = _pollers[s.mac];
      if (p != null && identical(p.session, s)) continue;
      p?.stop();
      if (s.infoChar == null) {
        _pollers.remove(s.mac);
        continue;
      }
      _pollers[s.mac] = _Poller(s)..start();
    }
    for (final mac in _pollers.keys.toList()) {
      if (!live.contains(mac)) _pollers.remove(mac)?.stop();
    }
  }
}

class _Poller {
  final DeviceSession session;
  Timer? _timer;
  bool _busy = false;
  bool _first = true;
  int _lastErrTotal = 0;

  _Poller(this.session);

  String get _seqKey => 'dh_seq_${session.mac}';
  String get _upKey => 'dh_up_${session.mac}';

  void start() {
    // Let the recording start (and write its header notes) first.
    _timer = Timer(const Duration(seconds: 3), () {
      _poll();
      _timer = Timer.periodic(DeviceHealth._period, (_) => _poll());
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    if (_busy || session.isDisposed) return;
    _busy = true;
    try {
      final info = await DeviceInfo.read(session.infoChar);
      final readAt = DateTime.now();
      if (info == null || session.isDisposed) return;
      session.info.value = info;
      await _log(info, readAt);
    } catch (e) {
      debugPrint('[DeviceHealth] ${session.mac}: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _log(DeviceInfo info, DateTime readAt) async {
    final csv = CsvRecorder.instance;
    final mac = session.mac;
    final prefs = await SharedPreferences.getInstance();

    var lastSeq = prefs.getInt(_seqKey) ?? 0;
    final lastUp = prefs.getInt(_upKey);
    // Uptime went backwards → the device restarted since we last looked, and
    // its event numbering started over.
    if (lastUp != null && info.deviceTimeMs < lastUp) lastSeq = 0;

    var newest = lastSeq;
    var ok = true;
    for (final e in info.log) {
      if (e.seq <= lastSeq) continue;
      final when = readAt
          .subtract(Duration(milliseconds: info.deviceTimeMs - e.timeMs));
      ok = await csv.logEvent(mac, 'Device: ${e.describe()}', at: when);
      if (!ok) break;
      newest = e.seq;
    }
    if (ok) {
      await prefs.setInt(_seqKey, newest > lastSeq ? newest : lastSeq);
      await prefs.setInt(_upKey, info.deviceTimeMs);
    }

    final errTotal = info.flashErrors + info.notifyErrors;
    if (_first) {
      if (await csv.logEvent(mac, 'Device status: ${info.summary()}')) {
        _first = false;
        _lastErrTotal = errTotal;
      }
    } else if (errTotal > _lastErrTotal) {
      if (await csv.logEvent(
          mac,
          'Device WARNING: flash write errors ${info.flashErrors}, '
          'live notify errors ${info.notifyErrors} (history may have gaps)')) {
        _lastErrTotal = errTotal;
      }
    }
  }
}
