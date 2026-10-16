import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// ══════════════════════════════════════════════════════════════════════════
//  device_info.dart — the firmware's "device info" characteristic
//  (abcdef04-…, READ only): health counters + a small power/connection
//  event log. Mirrors `info_read_cb` in main.c.
//
//  Layout (little endian):
//    0 u8 version(=1)  1 u8 flags (bit0 history_ready, bit1 calibrated,
//                                  bit2 limits_active)
//    2 u16 flash_errors   4 u16 notify_errors   6 u16 hist_records
//    8 u32 device_time_ms 12 u32 reset_cause
//   16 f32 threshold  20 f32 noise_mean  24 f32 breath_mean
//   28 u16 log_count  30 u16 reserved
//   32.. log_count × { u32 time_ms, u8 type, u8 arg, u16 seq }  (oldest first)
//
//  Older firmware has no such characteristic: findChar returns null and the
//  rest of the app simply shows nothing.
// ══════════════════════════════════════════════════════════════════════════

const String kDeviceInfoCharUuid = 'abcdef04-1234-5678-1234-56789abcdef0';

class DeviceLogEntry {
  final int timeMs; // device uptime when it happened
  final int type;
  final int arg;
  final int seq;
  const DeviceLogEntry(this.timeMs, this.type, this.arg, this.seq);

  static const int powerOn = 1;
  static const int connected = 2;
  static const int disconnected = 3;
  static const int histSync = 4;
  static const int calibrated = 5;

  String describe() {
    switch (type) {
      case powerOn:
        return 'powered on / restarted (${DeviceInfo.resetCauseText(arg)})';
      case connected:
        return arg == 0
            ? 'phone connected'
            : 'connection attempt failed (BLE error 0x${arg.toRadixString(16)})';
      case disconnected:
        return 'link closed — ${DeviceInfo.disconnectReasonText(arg)}';
      case histSync:
        return 'sent $arg stored record(s) to the phone';
      case calibrated:
        return 'breath detection calibrated';
      default:
        return 'event $type ($arg)';
    }
  }
}

class DeviceInfo {
  final bool historyReady;
  final bool calibrated;
  final bool limitsActive;
  final int flashErrors;
  final int notifyErrors;
  final int histRecords;
  final int deviceTimeMs;
  final int resetCause;
  final double threshold;
  final double noiseMean;
  final double breathMean;
  final List<DeviceLogEntry> log;

  const DeviceInfo({
    required this.historyReady,
    required this.calibrated,
    required this.limitsActive,
    required this.flashErrors,
    required this.notifyErrors,
    required this.histRecords,
    required this.deviceTimeMs,
    required this.resetCause,
    required this.threshold,
    required this.noiseMean,
    required this.breathMean,
    required this.log,
  });

  bool get hasProblem => flashErrors > 0 || notifyErrors > 0 || !historyReady;

  /// One-line summary for the recording notes.
  String summary() {
    final b = StringBuffer('calibrated: ${calibrated ? 'yes' : 'no'}');
    if (calibrated) b.write(', threshold ${threshold.toStringAsFixed(1)}');
    b.write(', history buffer: ${historyReady ? 'ready' : 'NOT available'}'
        ' ($histRecords stored)');
    b.write(', flash errors: $flashErrors, notify errors: $notifyErrors');
    return b.toString();
  }

  static DeviceInfo? tryParse(List<int> raw) {
    if (raw.length < 32) return null;
    final bytes = Uint8List.fromList(raw);
    final v = ByteData.sublistView(bytes);
    if (v.getUint8(0) != 1) return null;
    final flags = v.getUint8(1);
    final count = v.getUint16(28, Endian.little);
    final log = <DeviceLogEntry>[];
    for (var i = 0; i < count; i++) {
      final o = 32 + i * 8;
      if (o + 8 > bytes.length) break;
      log.add(DeviceLogEntry(
        v.getUint32(o, Endian.little),
        v.getUint8(o + 4),
        v.getUint8(o + 5),
        v.getUint16(o + 6, Endian.little),
      ));
    }
    double f(int o) {
      final x = v.getFloat32(o, Endian.little);
      return x.isFinite ? x : 0.0;
    }

    return DeviceInfo(
      historyReady: (flags & 1) != 0,
      calibrated: (flags & 2) != 0,
      limitsActive: (flags & 4) != 0,
      flashErrors: v.getUint16(2, Endian.little),
      notifyErrors: v.getUint16(4, Endian.little),
      histRecords: v.getUint16(6, Endian.little),
      deviceTimeMs: v.getUint32(8, Endian.little),
      resetCause: v.getUint32(12, Endian.little),
      threshold: f(16),
      noiseMean: f(20),
      breathMean: f(24),
      log: log,
    );
  }

  static BluetoothCharacteristic? findChar(List<BluetoothService> services) {
    for (final svc in services) {
      for (final ch in svc.characteristics) {
        if (ch.uuid.toString().toLowerCase() == kDeviceInfoCharUuid) return ch;
      }
    }
    return null;
  }

  /// Reads the characteristic. Null on any failure (never throws).
  static Future<DeviceInfo?> read(BluetoothCharacteristic? ch) async {
    if (ch == null) return null;
    try {
      return tryParse(await ch.read());
    } catch (e) {
      debugPrint('[DeviceInfo] read failed: $e');
      return null;
    }
  }

  // Zephyr hwinfo reset-cause bits (low byte).
  static String resetCauseText(int c) {
    if (c == 0) return 'cause unknown';
    final parts = <String>[];
    if (c & 0x08 != 0) parts.add('power-on');
    if (c & 0x01 != 0) parts.add('reset pin');
    if (c & 0x02 != 0) parts.add('software reset');
    if (c & 0x04 != 0) parts.add('BROWN-OUT (low supply voltage)');
    if (c & 0x10 != 0) parts.add('WATCHDOG');
    if (c & 0x20 != 0) parts.add('debugger');
    if (c & 0x40 != 0) parts.add('security');
    if (c & 0x80 != 0) parts.add('low-power wake');
    return parts.isEmpty ? 'cause 0x${c.toRadixString(16)}' : parts.join(', ');
  }

  // BLE HCI disconnect reasons.
  static String disconnectReasonText(int r) {
    switch (r) {
      case 0x08:
        return 'link timed out (out of range / signal lost)';
      case 0x13:
        return 'phone ended the connection';
      case 0x14:
        return 'phone closed it (low resources)';
      case 0x15:
        return 'phone closed it (power off)';
      case 0x16:
        return 'device ended the connection';
      case 0x3D:
        return 'message integrity check failed';
      case 0x3E:
        return 'connection could not be established';
      default:
        return 'reason 0x${r.toRadixString(16)}';
    }
  }
}
