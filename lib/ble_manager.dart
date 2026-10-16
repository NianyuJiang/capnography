import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
// pointycastle exports a few class names (State, Padding, ...) that
// collide with Flutter's framework. We only need AES here, so hide the
// conflicting names to keep the rest of the codebase safe.
import 'package:pointycastle/export.dart' hide State, Padding;

import 'ble_history_sync.dart';
import 'device_info.dart';
import 'device_names.dart';
import 'device_session.dart';

// ══════════════════════════════════════════════════════════════════════════
//  Wire format constants
//
//  Two device families are supported:
//
//  1) Virtual ESP32 (test rig)
//     • Packet: 24 bytes plaintext = 6 × float32 little-endian
//     • float layout: [breath_flag, mic_rms, pCO2_ratio, temp, pd_405, pd_470]
//
//  2) Real NICU_MINI_BLE device
//     • Packet: 32 bytes ciphertext (AES-128 ECB + PKCS#7 padding)
//     • Decrypts to: 24 bytes plaintext = 6 × float32 little-endian
//     • float layout: [breath_flag, mic_rms, pCO2_ratio, temperature,
//                      PD_405_mean, PD_470_mean]
//
//  pCO2 is the 3rd float (index 2). breath_flag (index 0 -- 1.0 = breath,
//  0.0 = no breath) and mic_rms (index 1 -- the on-device smoothed mic RMS
//  value the firmware's auto-threshold detector compares against) used to
//  be unused phase_diff/mag_ratio placeholders; the firmware now sends
//  real values in both, consumed here for the mic RMS / breath waveform.
//  To change any of these later, edit the matching kXFloatIndex only.
// ══════════════════════════════════════════════════════════════════════════
const int kBreathFlagFloatIndex = 0;
const int kRmsFloatIndex = 1;
const int kCo2FloatIndex = 2;
const double kCo2MinY = 0.0;
const double kCo2MaxY = 8.0;
/// Maximum simultaneous sensor connections.
///
/// 8 is a deliberate, tested ceiling rather than a hardware one: this tablet's
/// BLE stack advertises 16 concurrent LE links and each sensor only notifies
/// once per ~30 s, so CPU/memory are nowhere near saturated. Android BLE link
/// scheduling is what gets unreliable first, typically past ~8 connections.
const int kMaxDevices = 8;

// ══════════════════════════════════════════════════════════════════════════
//  autoCo2Range — dynamic Y-axis range for CO2 waveform charts.
//
//  Real device payloads are only bounds-checked to 0–50 in [_onBytes] below,
//  so a fixed 0–8 scale (the old chart default) regularly clipped real
//  spikes and let the trace overshoot the chart's own box. This computes a
//  "nice" ceiling from the values actually being plotted, with headroom,
//  so the waveform always fits the space it's drawn in.
// ══════════════════════════════════════════════════════════════════════════
({double minY, double maxY}) autoCo2Range(Iterable<double> values) {
  double hi = 0.0;
  for (final v in values) {
    if (v > hi) hi = v;
  }
  final padded = hi * 1.15;
  final step = padded <= 10 ? 1.0 : (padded <= 25 ? 2.0 : 5.0);
  final maxY = (padded / step).ceil() * step;
  return (minY: 0.0, maxY: maxY < step ? step : maxY);
}

// ── Real-device AES-128 key ──────────────────────────────────────────────
// Firmware derives a 16-byte key from a 32-byte source:
//   aes_key16[i] = aes_key32[i] ^ aes_key32[i+16]   for i = 0..15
//   = (0x00 ^ 0x10), (0x01 ^ 0x11), ..., (0x0F ^ 0x1F)
//   = 0x10 repeated 16 times.
// If firmware ever rotates the key, change this constant.
final Uint8List _kRealDeviceAesKey =
    Uint8List.fromList(List.filled(16, 0x10));

// Real device sends exactly 32 bytes per notify (24B payload + 8B padding).
const int kRealDevicePacketBytes = 32;

enum BleStatus { idle, scanning, connecting, disconnected }

class ConnectResult {
  final bool ok;
  final String? error;
  final DeviceSession? session;
  const ConnectResult.success(this.session)
      : ok = true,
        error = null;
  const ConnectResult.failure(this.error)
      : ok = false,
        session = null;
}

// ══════════════════════════════════════════════════════════════════════════
//  BleManager — singleton, owns all DeviceSessions
// ══════════════════════════════════════════════════════════════════════════
class BleManager {
  BleManager._();
  static final BleManager instance = BleManager._();

  // Known custom service UUIDs that the firmware exposes
  static const List<String> _knownServiceUuids = [
    '12345678-1234-1234-1234-123456789abc', // virtual ESP32
    'abcdef01-1234-5678-1234-56789abcdef0', // real NICU_MINI_BLE (service)
    'abcdef02-1234-5678-1234-56789abcdef0', // legacy entry, kept for safety
  ];

  // ── Global state ──
  final ValueNotifier<BleStatus> statusNotifier = ValueNotifier(BleStatus.idle);
  final ValueNotifier<List<ScanResult>> scanResultsNotifier =
      ValueNotifier(const []);

  /// Live registry of connected devices, keyed by MAC.
  /// Widgets watch [sessionsNotifier] to know when devices come & go.
  final Map<String, DeviceSession> _sessions = {};
  final ValueNotifier<List<DeviceSession>> sessionsNotifier =
      ValueNotifier(const []);

  /// Per-sample stream — every device's data flows through here.
  /// CsvRecorder listens to this stream and routes samples to the right file.
  final StreamController<SampleEvent> _sampleCtrl =
      StreamController.broadcast();
  Stream<SampleEvent> get sampleStream => _sampleCtrl.stream;

  StreamSubscription? _scanSub;

  // ── Unplanned-disconnect reporting (auto re-connect) ──────────────────
  // Ids being disconnected ON PURPOSE by disconnect()/disconnectAll(): only
  // drops the app did NOT ask for are reported on [unplannedDrops].
  final Set<String> _plannedDisconnects = {};

  // Ids with a connect() in progress — stops a background auto re-connect
  // and a manual tap on the same device from creating two sessions.
  final Set<String> _connecting = {};
  final StreamController<DroppedDevice> _dropCtrl =
      StreamController.broadcast();

  /// Fires once for every connected device whose link drops WITHOUT the app
  /// having asked for it. A user-pressed disconnect is never reported here.
  Stream<DroppedDevice> get unplannedDrops => _dropCtrl.stream;

  // ─── Accessors ────────────────────────────────────────────────────────
  List<DeviceSession> get sessions => List.unmodifiable(_sessions.values);
  int get sessionCount => _sessions.length;
  bool get isFull => _sessions.length >= kMaxDevices;
  bool isConnected(String mac) => _sessions.containsKey(mac);
  DeviceSession? sessionFor(String mac) => _sessions[mac];

  void _publishSessions() {
    sessionsNotifier.value = List.unmodifiable(_sessions.values);
  }

  int _nextFreeSlot() {
    final used = _sessions.values.map((s) => s.slot).toSet();
    for (int i = 1; i <= kMaxDevices; i++) {
      if (!used.contains(i)) return i;
    }
    return _sessions.length + 1; // fallback (shouldn't happen due to isFull)
  }

  // ─── Scanning ─────────────────────────────────────────────────────────
  Future<void> startScan() async {
    if (statusNotifier.value == BleStatus.scanning) return;
    scanResultsNotifier.value = const [];
    statusNotifier.value = BleStatus.scanning;
    await FlutterBluePlus.stopScan();
    _scanSub?.cancel();

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      noteScanResults(results); // remember advertised names (see device_names.dart)
      final sorted = List<ScanResult>.from(results)
        ..sort((a, b) => b.rssi.compareTo(a.rssi));
      // Keep only the strongest 50 to avoid UI overload
      scanResultsNotifier.value =
          sorted.length > 50 ? sorted.sublist(0, 50) : sorted;
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    if (statusNotifier.value == BleStatus.scanning) {
      statusNotifier.value = BleStatus.idle;
    }
  }

  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    _scanSub?.cancel();
    if (statusNotifier.value == BleStatus.scanning) {
      statusNotifier.value = BleStatus.idle;
    }
  }

  // ─── Connect ──────────────────────────────────────────────────────────
  //
  // [standingFor]: instead of a 15 s attempt, place a STANDING connection
  // request that stays open for up to this long (used by auto re-connect on
  // iOS: the phone's Bluetooth chip connects by itself the moment the device
  // advertises, even with the app in the background). Uses
  // flutter_blue_plus' autoConnect. Cancel early with cancelStandingConnect.
  Future<ConnectResult> connect(
    BluetoothDevice device, {
    Map<String, dynamic>? meta,
    Duration? standingFor,
  }) async {
    final mac = device.remoteId.str;

    if (_sessions.containsKey(mac)) {
      return ConnectResult.failure('Already connected');
    }
    if (isFull) {
      return ConnectResult.failure(
          'Maximum of $kMaxDevices devices already connected');
    }
    if (!_connecting.add(mac)) {
      return ConnectResult.failure('Connection already in progress');
    }
    try {
      return await _connectInner(device, mac, meta, standingFor);
    } finally {
      _connecting.remove(mac);
    }
  }

  /// Standing connection requests in progress, by id → their cancel signal.
  final Map<String, Completer<void>> _standingCancels = {};

  /// Cancels a standing connection request (no-op if there is none).
  void cancelStandingConnect(String mac) {
    final c = _standingCancels[mac];
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Turns off flutter_blue_plus' auto-connect for [device] (left on after a
  /// standing connect) so iOS does not silently re-connect it after a drop
  /// when the app is not going to use it. Safe on a disconnected device.
  void clearAutoConnect(BluetoothDevice device) {
    if (_sessions.containsKey(device.remoteId.str)) return; // in use
    if (!device.isAutoConnectEnabled) return;
    unawaited(device.disconnect(queue: false, timeout: 3).catchError((_) {}));
  }

  /// Waits for a standing (autoConnect) request to connect. Null once
  /// connected, or the reason it gave up (timeout / cancelled) — in which
  /// case the request has been withdrawn.
  Future<String?> _waitStanding(
      BluetoothDevice device, String mac, Duration maxWait) async {
    final cancel = Completer<void>();
    _standingCancels[mac] = cancel;
    final done = Completer<String?>();
    StreamSubscription<BluetoothConnectionState>? sub;
    Timer? timer;
    try {
      await device.connect(autoConnect: true, mtu: null); // returns at once
      sub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.connected && !done.isCompleted) {
          done.complete(null);
        }
      });
      timer = Timer(maxWait, () {
        if (!done.isCompleted) {
          final m = maxWait.inMinutes;
          done.complete('The device did not come in range within '
              '${m >= 1 ? '$m min' : '${maxWait.inSeconds} s'}');
        }
      });
      unawaited(cancel.future.then((_) {
        if (!done.isCompleted) done.complete('Cancelled');
      }));
      final why = await done.future;
      if (why != null) {
        unawaited(device.disconnect(queue: false, timeout: 3).catchError((_) {}));
      }
      return why;
    } finally {
      await sub?.cancel();
      timer?.cancel();
      if (identical(_standingCancels[mac], cancel)) _standingCancels.remove(mac);
    }
  }

  Future<ConnectResult> _connectInner(
    BluetoothDevice device,
    String mac,
    Map<String, dynamic>? meta,
    Duration? standingFor,
  ) async {
    if (standingFor == null) statusNotifier.value = BleStatus.connecting;
    try {
      if (standingFor == null) {
        await device.connect(timeout: const Duration(seconds: 15));
      } else {
        final why = await _waitStanding(device, mac, standingFor);
        if (why != null) return ConnectResult.failure(why);
        statusNotifier.value = BleStatus.connecting;
      }

      final services = await device.discoverServices();
      for (final svc in services) {
        debugPrint('[BLE:$mac] Service ${svc.uuid}');
        for (final ch in svc.characteristics) {
          debugPrint('[BLE:$mac]   Char ${ch.uuid} notify=${ch.properties.notify}');
        }
      }

      final char = _findNotifyChar(services, mac);
      if (char == null) {
        await device.disconnect();
        statusNotifier.value = BleStatus.idle;
        return ConnectResult.failure(
            'No notify characteristic found on this device');
      }

      try {
        await device.requestMtu(64);
      } catch (_) {}
      await char.setNotifyValue(true);

      final session = DeviceSession(
        device: device,
        slot: _nextFreeSlot(),
        meta: meta,
      );
      session.notifyChar = char;
      session.historyChar = BleHistorySync.findHistoryChar(services);
      session.infoChar = DeviceInfo.findChar(services);
      session.startClock();

      session.notifySub = char.lastValueStream.listen((bytes) {
        if (bytes.isNotEmpty) _onBytes(session, bytes);
      });
      session.stateSub = _watchLink(session);

      _sessions[mac] = session;
      _publishSessions();
      statusNotifier.value = BleStatus.idle;
      return ConnectResult.success(session);
    } catch (e) {
      // Don't leave a half-open link behind (connected at the OS level but
      // with no session): the device would stop advertising.
      try {
        await device.disconnect();
      } catch (_) {}
      statusNotifier.value = BleStatus.idle;
      return ConnectResult.failure(e.toString());
    }
  }

  /// Watches a session's link; when it drops the session ends, reported on
  /// [unplannedDrops] unless the app asked for it.
  StreamSubscription<BluetoothConnectionState> _watchLink(
      DeviceSession session) {
    final mac = session.mac;
    return session.device.connectionState.listen((state) {
      if (state != BluetoothConnectionState.disconnected) return;
      if (!identical(_sessions[mac], session)) return;
      if (!_plannedDisconnects.contains(mac)) _emitDrop(session);
      _removeSession(mac, notifyStatus: false);
    });
  }

  void _emitDrop(DeviceSession session, {DateTime? at}) {
    _dropCtrl.add(DroppedDevice(
      device: session.device,
      mac: session.mac,
      label: session.patient ?? session.displayName,
      slot: session.slot,
      meta: Map<String, dynamic>.from(session.meta),
      at: at ?? DateTime.now(),
    ));
  }

  BluetoothCharacteristic? _findNotifyChar(
      List<BluetoothService> services, String mac) {
    // Priority 1: known UUIDs
    for (final svc in services) {
      final uuid = svc.uuid.toString().toLowerCase();
      if (_knownServiceUuids.contains(uuid)) {
        for (final ch in svc.characteristics) {
          // The history-sync characteristic also notifies; never use it for live data.
          if (ch.uuid.toString().toLowerCase() == kHistorySyncCharUuid) continue;
          if (ch.properties.notify || ch.properties.indicate) {
            debugPrint('[BLE:$mac] Matched known service $uuid');
            return ch;
          }
        }
      }
    }
    // Priority 2: any 128-bit custom service
    for (final svc in services) {
      final uuid = svc.uuid.toString().toLowerCase();
      if (uuid.contains('00805f9b34fb')) continue;
      if (uuid.length <= 8) continue;
      for (final ch in svc.characteristics) {
        if (ch.uuid.toString().toLowerCase() == kHistorySyncCharUuid) continue;
        if (ch.properties.notify || ch.properties.indicate) {
          debugPrint('[BLE:$mac] Using custom service $uuid');
          return ch;
        }
      }
    }
    return null;
  }

  // ─── Disconnect ───────────────────────────────────────────────────────
  Future<void> disconnect(String mac) async {
    final session = _sessions[mac];
    if (session == null) return;
    _plannedDisconnects.add(mac); // user asked — never auto re-connect this
    try {
      try {
        await session.device.disconnect();
      } catch (_) {}
      await _removeSession(mac);
    } finally {
      _plannedDisconnects.remove(mac);
    }
  }

  Future<void> disconnectAll() async {
    for (final mac in _sessions.keys.toList()) {
      await disconnect(mac);
    }
  }

  Future<void> _removeSession(String mac, {bool notifyStatus = true}) async {
    final session = _sessions.remove(mac);
    if (session == null) return;
    await session.dispose();
    _publishSessions();
    if (notifyStatus && _sessions.isEmpty) {
      statusNotifier.value = BleStatus.idle;
    }
  }

  // ─── Sample parsing ───────────────────────────────────────────────────
  static const int _minBytes = (kCo2FloatIndex + 1) * 4;

  void _onBytes(DeviceSession session, List<int> bytes) {
    // ── Step 1: detect packet format ────────────────────────────────
    // 32 bytes  → real NICU_MINI_BLE device (AES-encrypted, decrypt first)
    // anything else → virtual ESP32 (plaintext, use as-is)
    Uint8List payload;
    if (bytes.length == kRealDevicePacketBytes) {
      try {
        payload = _aesDecryptRealDevice(Uint8List.fromList(bytes));
      } catch (e) {
        debugPrint('[BLE:${session.mac}] AES decrypt failed: $e');
        return;
      }
    } else {
      payload = Uint8List.fromList(bytes);
    }

    // ── Step 2: bounds check ────────────────────────────────────────
    if (payload.length < _minBytes) {
      debugPrint(
          '[BLE:${session.mac}] packet too short (${payload.length}B)');
      return;
    }

    // ── Step 3: parse pCO2, breath_flag, and mic_rms ────────────────
    try {
      final view = ByteData.sublistView(payload);
      final co2Raw = view.getFloat32(kCo2FloatIndex * 4, Endian.little);
      final flagRaw =
          view.getFloat32(kBreathFlagFloatIndex * 4, Endian.little);
      final rmsRaw = view.getFloat32(kRmsFloatIndex * 4, Endian.little);

      // NaN/Inf guard: skip a corrupt part and hold the last valid value.
      final co2Ok = co2Raw.isFinite;
      final rmsOk = rmsRaw.isFinite && flagRaw.isFinite;
      if (!co2Ok && !rmsOk) {
        debugPrint('[BLE] dropped non-finite packet');
        return;
      }
      final co2 =
          co2Ok ? co2Raw.clamp(0.0, 50.0).toDouble() : session.currentCo2;
      final rms = rmsOk ? rmsRaw : session.currentRms;
      final isBreath = rmsOk ? flagRaw >= 0.5 : session.currentBreath;

      if (co2Ok) session.addSample(co2);
      if (rmsOk) session.addRmsSample(rms, isBreath);
      _sampleCtrl.add(SampleEvent(
        session: session,
        co2: co2,
        rms: rms,
        breath: isBreath,
      ));
    } catch (e) {
      debugPrint('[BLE:${session.mac}] parse error: $e');
    }
  }

  // ─── AES-128 ECB decryption for real NICU_MINI_BLE device ─────────────
  // Input  : 32-byte ciphertext from BLE notify
  // Output : 24-byte plaintext (after stripping PKCS#7 padding)
  //          = 6 × float32 little-endian
  Uint8List _aesDecryptRealDevice(Uint8List ciphertext) {
    if (ciphertext.isEmpty || ciphertext.length % 16 != 0) {
      throw FormatException(
          'Invalid AES ciphertext length: ${ciphertext.length}');
    }
    final cipher = ECBBlockCipher(AESEngine())
      ..init(false, KeyParameter(_kRealDeviceAesKey)); // false = decrypt mode

    final plaintext = Uint8List(ciphertext.length);
    for (int offset = 0; offset < ciphertext.length; offset += 16) {
      cipher.processBlock(ciphertext, offset, plaintext, offset);
    }

    // Strip PKCS#7 padding: last byte tells us how many padding bytes there are
    final padLen = plaintext.last;
    if (padLen >= 1 && padLen <= 16) {
      return plaintext.sublist(0, plaintext.length - padLen);
    }
    // Padding byte out of range — return as-is and let the caller decide
    return plaintext;
  }

  void dispose() {
    _sampleCtrl.close();
    _dropCtrl.close();
    _scanSub?.cancel();
  }
}

// ══════════════════════════════════════════════════════════════════════════
class SampleEvent {
  final DeviceSession session;
  final double co2;
  final double rms;
  final bool breath;
  const SampleEvent({
    required this.session,
    required this.co2,
    required this.rms,
    required this.breath,
  });
}

// ══════════════════════════════════════════════════════════════════════════
//  A device whose link dropped without the app asking (see
//  BleManager.unplannedDrops). Holds what auto_reconnect.dart needs to bring
//  the same device back.
// ══════════════════════════════════════════════════════════════════════════
class DroppedDevice {
  final BluetoothDevice device;
  final String mac;
  final String label; // patient or display name, for the UI
  final int slot;
  final Map<String, dynamic> meta;
  final DateTime at;
  const DroppedDevice({
    required this.device,
    required this.mac,
    required this.label,
    required this.slot,
    required this.meta,
    required this.at,
  });
}
