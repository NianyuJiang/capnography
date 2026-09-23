// ════════════════════════════════════════════════════════════════════════
//  device_session.dart
//  Confidence: HIGH — I wrote the complete file in this conversation.
//  This is verbatim what I produced. AES refactor in the other
//  conversation did not change this file (it's pure data architecture).
// ════════════════════════════════════════════════════════════════════════
import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:fl_chart/fl_chart.dart' show FlSpot;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// ══════════════════════════════════════════════════════════════════════════
//  DeviceSession
//  ─────────────────────────────────────────────────────────────────────────
//  One instance per connected device. Holds everything that belongs to
//  that device — BLE handle, subscription, waveform buffer, current values,
//  session timing, optional patient metadata.
//
//  Lives as long as the device is connected. Survives page navigation
//  because it's owned by BleManager (a singleton), not any widget.
// ══════════════════════════════════════════════════════════════════════════
class DeviceSession {
  static const int maxPoints = 300;

  final BluetoothDevice device;
  final int slot; // display number 1..4

  /// Optional patient/device info supplied by a QR scan.
  ///   keys: mac, name, patient, age, note
  /// `mac` is always present; everything else may be missing or empty.
  final Map<String, dynamic> meta;

  // ── BLE wiring ──
  BluetoothCharacteristic? notifyChar;
  StreamSubscription? notifySub;
  StreamSubscription? stateSub;

  // ── Live data ──
  final Queue<FlSpot> points = Queue<FlSpot>();
  double currentCo2 = 0.0;
  double peakCo2 = 0.0;
  int breathCount = 0;
  double _x = 0.0;
  bool _aboveThreshold = false;
  static const double _hi = 0.5;
  static const double _lo = 0.3;

  // ── Session timing ──
  final DateTime connectedAt = DateTime.now();
  final ValueNotifier<String> elapsedNotifier = ValueNotifier('00:00:00');
  Timer? _clock;

  // ── Per-tick notifier so widgets can rebuild just this session ──
  final ValueNotifier<int> tick = ValueNotifier(0);

  DeviceSession({
    required this.device,
    required this.slot,
    Map<String, dynamic>? meta,
  }) : meta = meta ?? const {};

  String get mac => device.remoteId.str;

  String get displayName {
    final fromMeta = (meta['name'] as String?)?.trim();
    if (fromMeta != null && fromMeta.isNotEmpty) return fromMeta;
    final fromBle = device.platformName.trim();
    if (fromBle.isNotEmpty) return fromBle;
    return 'Device #$slot';
  }

  String? get patient {
    final p = (meta['patient'] as String?)?.trim();
    return (p == null || p.isEmpty) ? null : p;
  }

  void startClock() {
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      final e = DateTime.now().difference(connectedAt);
      elapsedNotifier.value =
          '${e.inHours.toString().padLeft(2, '0')}:'
          '${(e.inMinutes % 60).toString().padLeft(2, '0')}:'
          '${(e.inSeconds % 60).toString().padLeft(2, '0')}';
    });
  }

  void stopClock() {
    _clock?.cancel();
  }

  /// Process a new CO2 sample from this device.
  void addSample(double co2) {
    currentCo2 = co2;
    if (co2 > peakCo2) peakCo2 = co2;

    if (!_aboveThreshold && co2 >= _hi) {
      _aboveThreshold = true;
      breathCount++;
    } else if (_aboveThreshold && co2 < _lo) {
      _aboveThreshold = false;
    }

    points.add(FlSpot(_x++, co2));
    if (points.length > maxPoints) points.removeFirst();
    tick.value++;
  }

  void resetStats() {
    peakCo2 = 0;
    breathCount = 0;
    _aboveThreshold = false;
    tick.value++;
  }

  double get breathRate {
    final secs = DateTime.now().difference(connectedAt).inSeconds;
    if (secs < 5) return 0;
    return (breathCount * 60) / secs;
  }

  Future<void> dispose() async {
    stopClock();
    await notifySub?.cancel();
    await stateSub?.cancel();
    elapsedNotifier.dispose();
    tick.dispose();
  }
}
