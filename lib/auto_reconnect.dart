import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart' show DateFormat;

import 'ble_manager.dart';
import 'csv_recorder.dart';

// ══════════════════════════════════════════════════════════════════════════
//  auto_reconnect.dart — optional automatic re-connect after a SHORT,
//  UNPLANNED disconnect (walked away with the phone, weak signal, brief
//  loss of the link). Ported from the NICU app.
//
//  • Per device, switched on from the device's detail page. DEFAULT IS OFF.
//    Remembered (by device id) only while the app is running.
//  • Only drops the app did NOT ask for trigger it. Pressing disconnect
//    never auto re-connects.
//  • For up to [window] (10 min) after the drop:
//      iOS     one standing connection request for the whole window — iOS
//              connects by itself as soon as the device advertises, even
//              with the app in the background.
//      Android repeated 15 s connection attempts.
//  • A successful re-connect CONTINUES the same recording (same path as
//    answering "continue" by hand), so what the device stored in its own
//    memory while away is backfilled. A line is added to the recording's
//    notes. Every unplanned drop is noted, whether or not auto re-connect
//    is on.
//  • After 10 minutes without success it gives up and says so on the
//    Monitor page.
// ══════════════════════════════════════════════════════════════════════════

enum ReconnectState { trying, gaveUp }

class ReconnectAttempt {
  final String mac;
  final String label;
  final DroppedDevice drop;
  final DateTime lostAt;
  final DateTime deadline;
  ReconnectState state = ReconnectState.trying;
  int tries = 0;
  bool cancelled = false;

  ReconnectAttempt({
    required this.mac,
    required this.label,
    required this.drop,
    required this.lostAt,
    required this.deadline,
  });
}

class AutoReconnect {
  AutoReconnect._();
  static final AutoReconnect instance = AutoReconnect._();

  static const Duration window = Duration(minutes: 10);
  static const Duration _retryGap = Duration(seconds: 5);
  static const Duration _settle = Duration(seconds: 2);

  /// Device ids with auto re-connect switched ON.
  final ValueNotifier<Set<String>> enabledMacs = ValueNotifier(const {});

  /// Devices currently being re-connected (or given up on), for the banner.
  final ValueNotifier<List<ReconnectAttempt>> attempts =
      ValueNotifier(const []);

  StreamSubscription<DroppedDevice>? _dropSub;

  bool isEnabled(String mac) => enabledMacs.value.contains(mac);

  void setEnabled(String mac, bool on) {
    final next = Set<String>.from(enabledMacs.value);
    if (on) {
      next.add(mac);
    } else {
      next.remove(mac);
      cancel(mac);
    }
    enabledMacs.value = Set.unmodifiable(next);
  }

  void init() {
    _dropSub ??= BleManager.instance.unplannedDrops.listen(_onDrop);
    BleManager.instance.sessionsNotifier.addListener(_pruneGaveUp);
  }

  void _pruneGaveUp() {
    final ble = BleManager.instance;
    final list = attempts.value;
    final keep = list
        .where((a) =>
            !(a.state == ReconnectState.gaveUp && ble.isConnected(a.mac)))
        .toList();
    if (keep.length != list.length) attempts.value = List.unmodifiable(keep);
  }

  /// Stops trying for [mac] (or dismisses its "gave up" banner).
  void cancel(String mac) {
    final list = attempts.value;
    for (final a in list) {
      if (a.mac == mac) {
        a.cancelled = true;
        BleManager.instance.cancelStandingConnect(a.mac);
        BleManager.instance.clearAutoConnect(a.drop.device);
      }
    }
    attempts.value =
        List.unmodifiable(list.where((a) => a.mac != mac).toList());
  }

  void _publish() => attempts.value = List.unmodifiable(attempts.value);

  void _onDrop(DroppedDevice drop) {
    // Always note an unplanned drop in the recording (reason for gaps).
    unawaited(CsvRecorder.instance.logEvent(
      drop.mac,
      isEnabled(drop.mac)
          ? 'Connection lost (not requested) — auto re-connect will try for '
              '${window.inMinutes} min'
          : 'Connection lost (not requested) — auto re-connect is off',
      at: drop.at,
      toLatestIfIdle: true,
    ));

    if (!isEnabled(drop.mac)) {
      BleManager.instance.clearAutoConnect(drop.device);
      return;
    }
    if (attempts.value.any((a) => a.mac == drop.mac)) {
      cancel(drop.mac); // replace an old "gave up" entry with a fresh try
    }
    final a = ReconnectAttempt(
      mac: drop.mac,
      label: drop.label,
      drop: drop,
      lostAt: drop.at,
      deadline: drop.at.add(window),
    );
    attempts.value = List.unmodifiable([...attempts.value, a]);
    unawaited(_run(drop, a));
  }

  Future<void> _run(DroppedDevice drop, ReconnectAttempt a) async {
    final ble = BleManager.instance;
    final csv = CsvRecorder.instance;
    await Future.delayed(_settle);

    while (!a.cancelled && DateTime.now().isBefore(a.deadline)) {
      if (ble.isConnected(drop.mac)) {
        _finish(a); // connected by hand meanwhile
        return;
      }
      if (ble.isFull) {
        await _sleep(a, _retryGap);
        continue;
      }

      a.tries++;
      _publish();
      ConnectResult? res;
      var primed = false;
      try {
        // The dropped connection's recording must be fully closed first, so
        // "the most recent recording" below is the one just interrupted.
        await csv.waitIdle();
        final previous =
            await CsvRecorder.mostRecentRecordingForMac(drop.mac);

        final remaining = a.deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) break;
        if (a.cancelled) break;
        csv.clearPendingResume(drop.mac);
        if (previous != null) csv.markPendingResume(drop.mac, previous);
        primed = true;
        res = await ble.connect(drop.device,
            meta: drop.meta, standingFor: Platform.isIOS ? remaining : null);
      } catch (e) {
        debugPrint('[AutoReconnect] ${drop.mac}: $e');
        res = null;
      }

      if (res != null && res.ok) {
        final session = res.session;
        if (a.cancelled) {
          // STOP pressed while this attempt was connecting: close the link
          // again (the recording is kept).
          if (session != null) await ble.disconnect(session.mac);
          return;
        }
        _finish(a);
        if (session != null) unawaited(_logSuccess(session.mac, a));
        return;
      }
      // Failed: never leave a resume request behind for a later, unrelated
      // connection of this device.
      if (primed) csv.clearPendingResume(drop.mac);
      await _sleep(a, _retryGap);
    }

    // Leaving without a session: no request may stay behind, or iOS would
    // connect it later with nobody using the link.
    ble.clearAutoConnect(drop.device);
    if (a.cancelled) return;
    a.state = ReconnectState.gaveUp;
    _publish();
    unawaited(CsvRecorder.instance.logEvent(
      drop.mac,
      'Auto re-connect gave up after ${window.inMinutes} min — '
      'reconnect by hand',
      toLatestIfIdle: true,
    ));
  }

  void _finish(ReconnectAttempt a) {
    a.cancelled = true;
    attempts.value = List.unmodifiable(
        attempts.value.where((x) => !identical(x, a)).toList());
  }

  Future<void> _sleep(ReconnectAttempt a, Duration d) async {
    final until = DateTime.now().add(d);
    while (!a.cancelled && DateTime.now().isBefore(until)) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> _logSuccess(String mac, ReconnectAttempt a) async {
    final away = DateTime.now().difference(a.lostAt);
    final m = away.inMinutes;
    final s = away.inSeconds % 60;
    final text = 'Auto re-connected — link lost at '
        '${DateFormat('HH:mm:ss').format(a.lostAt)}, back after '
        '${m > 0 ? '${m}m ' : ''}${s}s (attempt ${a.tries})';
    final ok = await CsvRecorder.instance.logEvent(mac, text);
    if (!ok) debugPrint('[AutoReconnect] could not log: $text');
  }
}
