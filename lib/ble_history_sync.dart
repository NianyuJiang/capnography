import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// ══════════════════════════════════════════════════════════════════════════
//  BleHistorySync — talks to the firmware's flash history buffer.
//
//  Ported from the NICU app's ble_history_sync.dart, adapted to this
//  device's 16-byte, 1 Hz summary records.
//
//  While no phone is subscribed to live data, the device stores one record
//  per second (breath flag = any breath that second, RMS = peak that
//  second, latest pCO2/PD values). After reconnecting, the app:
//    1. subscribes to the history characteristic (abcdef03-...),
//    2. WRITEs a 4-byte little-endian uint32: "send everything after this
//       sequence number" (0 = all),
//    3. receives the records oldest-first, ending with a marker record
//       (seq == 0xFFFFFFFF) that carries the device's uptime at that
//       moment — paired with the phone clock when it arrives, that dates
//       every record exactly,
//    4. WRITEs 0xFFFFFFFE to make the device clear its buffer.
//
//  A device on older firmware has no such characteristic: every call here
//  degrades gracefully (returns null) rather than throwing.
// ══════════════════════════════════════════════════════════════════════════

const String kHistoryServiceUuid = 'abcdef01-1234-5678-1234-56789abcdef0';
const String kHistorySyncCharUuid = 'abcdef03-1234-5678-1234-56789abcdef0';
const int kHistoryClearCommand = 0xFFFFFFFE;

/// One stored second — mirrors `struct history_record` in main.c.
class HistorySample {
  final int seq;
  final int deviceTimeMs;
  final double rms;
  final bool breath;
  final double pco2;
  final int pd405;
  final int pd470;

  const HistorySample({
    required this.seq,
    required this.deviceTimeMs,
    required this.rms,
    required this.breath,
    required this.pco2,
    required this.pd405,
    required this.pd470,
    this.rawRmsFlag = 0,
    this.rawPco2 = 0,
  });

  /// Raw u16 fields (the end-of-sync marker reuses them for its counters).
  final int rawRmsFlag;
  final int rawPco2;

  static const int wireBytes = 16;
  static const int sentinelSeq = 0xFFFFFFFF;

  /// seq(u32) device_time_ms(u32) rms_flag(u16) pco2_x1000(u16) pd405(u16)
  /// pd470(u16), little-endian. rms_flag: bit15 = breath, bits0..14 = RMS x10.
  static HistorySample? tryParse(Uint8List bytes) {
    if (bytes.length != wireBytes) return null;
    final v = ByteData.sublistView(bytes);
    final rmsFlag = v.getUint16(8, Endian.little);
    final pco2Raw = v.getUint16(10, Endian.little);
    return HistorySample(
      seq: v.getUint32(0, Endian.little),
      deviceTimeMs: v.getUint32(4, Endian.little),
      rms: (rmsFlag & 0x7FFF) / 10.0,
      breath: (rmsFlag & 0x8000) != 0,
      pco2: pco2Raw / 1000.0,
      pd405: v.getUint16(12, Endian.little),
      pd470: v.getUint16(14, Endian.little),
      rawRmsFlag: rmsFlag,
      rawPco2: pco2Raw,
    );
  }

  /// End-of-sync marker: seq 0xFFFFFFFF with a real uptime. (An erased flash
  /// slot would read all 0xFF, i.e. uptime 0xFFFFFFFF — not a marker.)
  bool get isSentinel => seq == sentinelSeq && deviceTimeMs != 0xFFFFFFFF;
  bool get isErasedSlot => seq == sentinelSeq && deviceTimeMs == 0xFFFFFFFF;
}

class HistorySyncResult {
  final List<HistorySample> records;
  final bool complete;

  /// Device uptime in the end-of-sync marker, and the phone clock when the
  /// marker arrived. Null if the marker never arrived.
  final int? anchorDeviceMs;
  final DateTime? anchorWall;

  final String endReason;
  final String? failure;
  final int duplicates;

  /// Device's own counts from the marker (null if the marker never arrived).
  final int? deviceSent;
  final int? deviceDropped;

  const HistorySyncResult(
    this.records, {
    required this.complete,
    this.anchorDeviceMs,
    this.anchorWall,
    this.endReason = 'end marker',
    this.failure,
    this.duplicates = 0,
    this.deviceSent,
    this.deviceDropped,
  });

  /// Wall-clock time of [s], from the marker anchor. Null without an anchor.
  DateTime? wallTimeOf(HistorySample s) {
    if (anchorDeviceMs == null || anchorWall == null) return null;
    final ago = anchorDeviceMs! - s.deviceTimeMs;
    return anchorWall!.subtract(Duration(milliseconds: ago));
  }
}

class BleHistorySync {
  BleHistorySync._();

  static BluetoothCharacteristic? findHistoryChar(
      List<BluetoothService> services) {
    for (final svc in services) {
      if (svc.uuid.toString().toLowerCase() != kHistoryServiceUuid) continue;
      for (final ch in svc.characteristics) {
        if (ch.uuid.toString().toLowerCase() == kHistorySyncCharUuid) {
          return ch;
        }
      }
    }
    return null;
  }

  /// Tells the device to clear its history buffer. Best effort; never throws.
  static Future<void> clear(BluetoothCharacteristic? historyChar) async {
    if (historyChar == null) return;
    try {
      final req = ByteData(4)
        ..setUint32(0, kHistoryClearCommand, Endian.little);
      await historyChar.write(req.buffer.asUint8List(),
          withoutResponse: false);
      debugPrint('[HistSync] device history cleared');
    } catch (e) {
      debugPrint('[HistSync] clear failed: $e');
    }
  }

  /// Requests every buffered record with seq > [sinceSeq] and collects them
  /// until the end marker arrives, nothing arrives for [idleTimeout], or
  /// [maxDuration] elapses. Returns null if the device has no history
  /// characteristic (older firmware).
  static Future<HistorySyncResult?> sync(
    BluetoothCharacteristic? historyChar, {
    int sinceSeq = 0,
    Duration idleTimeout = const Duration(seconds: 10),
    Duration maxDuration = const Duration(minutes: 5),
  }) async {
    final char = historyChar;
    if (char == null) {
      debugPrint('[HistSync] no history characteristic (older firmware)');
      return null;
    }

    final results = <HistorySample>[];
    final completer = Completer<void>();
    StreamSubscription? sub;
    Timer? idleTimer;
    var complete = false;
    int? anchorDeviceMs;
    DateTime? anchorWall;
    int? deviceSent;
    int? deviceDropped;
    var stage = 'enable notifications';
    String? failure;
    var endReason = 'end marker';

    void armIdle() {
      idleTimer?.cancel();
      idleTimer = Timer(idleTimeout, () {
        if (!completer.isCompleted) {
          endReason = 'no data for ${idleTimeout.inSeconds}s';
          completer.complete();
        }
      });
    }

    try {
      await char.setNotifyValue(true);
      stage = 'subscribe';
      // onValueReceived (not lastValueStream) so a cached value is never
      // mistaken for a record.
      sub = char.onValueReceived.listen((bytes) {
        final s = HistorySample.tryParse(Uint8List.fromList(bytes));
        if (s == null || s.isErasedSlot) return;
        if (s.isSentinel) {
          complete = true;
          anchorDeviceMs = s.deviceTimeMs;
          anchorWall = DateTime.now();
          deviceSent = s.rawRmsFlag;
          deviceDropped = s.rawPco2;
          if (!completer.isCompleted) completer.complete();
          return;
        }
        results.add(s);
        armIdle();
      });

      stage = 'send request';
      final req = ByteData(4)..setUint32(0, sinceSeq, Endian.little);
      await char.write(req.buffer.asUint8List(), withoutResponse: false);
      stage = 'wait for records';
      armIdle();

      await completer.future.timeout(maxDuration, onTimeout: () {
        endReason = '${maxDuration.inMinutes} min cap';
      });
    } catch (e) {
      failure = '$stage: $e';
      endReason = 'error';
      debugPrint('[HistSync] sync failed at $stage: $e');
    } finally {
      idleTimer?.cancel();
      await sub?.cancel();
      try {
        await char.setNotifyValue(false);
      } catch (_) {}
    }

    results.sort((a, b) => a.seq.compareTo(b.seq));
    final deduped = <HistorySample>[];
    for (final r in results) {
      if (deduped.isEmpty || deduped.last.seq != r.seq) deduped.add(r);
    }
    return HistorySyncResult(
      deduped,
      complete: complete,
      anchorDeviceMs: anchorDeviceMs,
      anchorWall: anchorWall,
      endReason: endReason,
      failure: failure,
      duplicates: results.length - deduped.length,
      deviceSent: deviceSent,
      deviceDropped: deviceDropped,
    );
  }
}
