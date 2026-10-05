import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ble_manager.dart';
import 'connect_flow.dart';
import 'device_names.dart';
import 'device_session.dart';
import 'glass.dart';
import 'scan_qr_page.dart';
import 'theme_manager.dart';

// ══════════════════════════════════════════════════════════════════════════
//  KnownDevices — like a phone's Bluetooth pairing list (persisted)
// ══════════════════════════════════════════════════════════════════════════
class KnownDevices {
  KnownDevices._();
  static final KnownDevices instance = KnownDevices._();

  static const _key = 'capno_known_devices_v1';
  Map<String, String> _map = {};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? const [];
    _map = {
      for (final entry in list)
        if (entry.contains('|'))
          entry.split('|').first: entry.split('|').sublist(1).join('|'),
    };
    _loaded = true;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _key,
      _map.entries.map((e) => '${e.key}|${e.value}').toList(),
    );
  }

  Future<void> remember(String mac, String name) async {
    await load();
    _map[mac] = name;
    await _save();
  }

  Future<void> forget(String mac) async {
    await load();
    _map.remove(mac);
    await _save();
  }

  bool isKnown(String mac) => _map.containsKey(mac);
  String? nameOf(String mac) => _map[mac];
  List<MapEntry<String, String>> get all => _map.entries.toList();
}

// ══════════════════════════════════════════════════════════════════════════
class BlePage extends StatefulWidget {
  const BlePage({super.key});
  @override
  State<BlePage> createState() => _BlePageState();
}

class _BlePageState extends State<BlePage> {
  final _ble = BleManager.instance;
  bool _permsReady = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await KnownDevices.instance.load();
    final ok = await _requestPermissions();
    if (!mounted) return;
    setState(() => _permsReady = ok);
    if (ok) _ble.startScan();
  }

  Future<bool> _requestPermissions() async {
    // Permission.bluetoothScan / bluetoothConnect are Android 12+ split
    // permissions with no iOS equivalent -- permission_handler's iOS side
    // doesn't implement them at all, so they report `.denied` forever on
    // iOS no matter what the user approves (this is a known upstream
    // limitation, see Baseflow/flutter-permission-handler#1418). Core
    // Bluetooth scanning itself works fine on iOS regardless (gated only
    // by NSBluetoothAlwaysUsageDescription in Info.plist) -- it was only
    // this app-level permission *gate* that could never pass, hiding scan
    // results the OS had already found. On iOS, check Permission.bluetooth
    // instead, which the plugin does map to Core Bluetooth's authorization.
    if (Platform.isIOS) {
      final status = await Permission.bluetooth.request();
      return status.isGranted;
    }

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connectOk =
        statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    return scanOk && connectOk;
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (_ble.isFull) {
      _snack(
        'Maximum $kMaxDevices devices already connected. Disconnect one first.',
        ThemeManager.orange,
      );
      return;
    }
    await _ble.stopScan();

    // Build a minimal meta dict from the BLE advertisement so the rest of
    // the app (CSV recorder → session_metadata) gets the same `name` field
    // it would get from a QR-code connect. This makes the auto-fill of the
    // session title work whether the user scans a QR or taps the device
    // in the Bluetooth list.
    final advName = bleNameOf(device);
    final knownName = KnownDevices.instance.nameOf(device.remoteId.str) ?? '';
    final resolvedName = advName.isNotEmpty
        ? advName
        : (knownName.isNotEmpty ? knownName : '');
    final meta = <String, dynamic>{
      if (resolvedName.isNotEmpty) 'name': resolvedName,
    };

    // "New patient?" / "Continue recording?" — only asked if this device has
    // a previous recording (see connect_flow.dart).
    await maybeShowConnectDialogs(context, mac: device.remoteId.str);
    if (!mounted) return;

    final res = await _ble.connect(device, meta: meta);
    if (!mounted) return;
    if (!res.ok) {
      _snack('Connection failed: ${res.error}', ThemeManager.red);
      return;
    }
    final name = resolvedName.isEmpty ? 'Unknown' : resolvedName;
    await KnownDevices.instance.remember(device.remoteId.str, name);
    if (!mounted) return;
    _snack('Connected: $name', ThemeManager.green);
    setState(() {}); // refresh known list
  }

  Future<void> _connectToKnown(String mac, String name) async {
    final device = BluetoothDevice.fromId(mac);
    await _connectToDevice(device);
  }

  Future<void> _forgetDevice(String mac, String name) async {
    final tm = ThemeManager.instance;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26)),
        child: GlassCard(
          borderRadius: 26,
          accent: ThemeManager.red,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'FORGET DEVICE',
                style: TextStyle(
                  color: ThemeManager.red,
                  fontSize: 11,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              Text(name,
                  style: TextStyle(
                      color: tm.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(mac, style: TextStyle(color: tm.textSub, fontSize: 11)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text('CANCEL',
                          style: TextStyle(
                              color: tm.textSub,
                              fontSize: 11,
                              letterSpacing: 2,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('FORGET',
                          style: TextStyle(
                              color: ThemeManager.red,
                              fontSize: 11,
                              letterSpacing: 2,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirm == true) {
      await KnownDevices.instance.forget(mac);
      if (mounted) setState(() {});
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: color,
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LiquidBackground(
        child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context, tm),
              const SizedBox(height: 18),
              _buildStatusRow(tm),
              const SizedBox(height: 18),
              if (!_permsReady)
                Expanded(child: _buildPermsRequired(tm))
              else
                Expanded(child: _buildDeviceLists(tm)),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ThemeManager tm) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      // Buttons flush to the top; the QR button carries a caption underneath.
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: GlassCard(
            borderRadius: 13,
            elevated: false,
            child: SizedBox(
              width: 38,
              height: 38,
              child: Icon(Icons.arrow_back_ios_new,
                  color: tm.textPrimary, size: 14),
            ),
          ),
        ),
        const SizedBox(
          height: 38,
          child: Center(
            child: Text(
              'BLUETOOTH',
              style: TextStyle(
                color: ThemeManager.purple,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 3.5,
              ),
            ),
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 📷 QR scan
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ScanQRPage()),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlassCard(
                    borderRadius: 13,
                    accent: ThemeManager.cyan,
                    elevated: false,
                    child: const SizedBox(
                      width: 38,
                      height: 38,
                      child: Icon(Icons.qr_code_scanner,
                          color: ThemeManager.cyan, size: 16),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Scan device',
                    style: TextStyle(
                      color: tm.textSub,
                      fontSize: 8,
                      letterSpacing: 0.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Scan / Stop
            ValueListenableBuilder<BleStatus>(
              valueListenable: _ble.statusNotifier,
              builder: (_, status, __) {
                final scanning = status == BleStatus.scanning;
                return GestureDetector(
                  onTap: scanning ? _ble.stopScan : _ble.startScan,
                  child: GlassCard(
                    borderRadius: 13,
                    accent: scanning ? ThemeManager.purple : null,
                    elevated: false,
                    child: SizedBox(
                      width: 38,
                      height: 38,
                      child: scanning
                          ? const Center(
                              child: SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.6,
                                  color: ThemeManager.purple,
                                ),
                              ),
                            )
                          : Icon(Icons.radar,
                              color: tm.textPrimary, size: 16),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatusRow(ThemeManager tm) {
    return ValueListenableBuilder<BleStatus>(
      valueListenable: _ble.statusNotifier,
      builder: (_, status, __) {
        return ValueListenableBuilder<List<DeviceSession>>(
          valueListenable: _ble.sessionsNotifier,
          builder: (_, sessions, __) {
            final (msg, color) = switch (status) {
              BleStatus.scanning => ('SCANNING…', ThemeManager.cyan),
              BleStatus.connecting => ('CONNECTING…', ThemeManager.purple),
              _ => sessions.isNotEmpty
                  ? ('${sessions.length} CONNECTED', ThemeManager.green)
                  : ('READY', tm.textSub),
            };
            return Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration:
                      BoxDecoration(shape: BoxShape.circle, color: color),
                ),
                const SizedBox(width: 8),
                Text(
                  msg,
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    letterSpacing: 2.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                ValueListenableBuilder<List<ScanResult>>(
                  valueListenable: _ble.scanResultsNotifier,
                  builder: (_, list, __) => Text(
                    '${list.length} nearby',
                    style: TextStyle(
                      color: tm.textSub,
                      fontSize: 10,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildPermsRequired(ThemeManager tm) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bluetooth_disabled,
              size: 48, color: ThemeManager.red.withValues(alpha: 0.6)),
          const SizedBox(height: 16),
          Text(
            'PERMISSION NEEDED',
            style: TextStyle(
              color: tm.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'This app needs Bluetooth and Location permission to scan for sensors.',
              textAlign: TextAlign.center,
              style: TextStyle(color: tm.textSub, fontSize: 12, height: 1.4),
            ),
          ),
          const SizedBox(height: 20),
          GlassPill(
            onTap: () => openAppSettings(),
            accent: ThemeManager.purple,
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: const Text(
              'OPEN SETTINGS',
              style: TextStyle(
                color: ThemeManager.purple,
                fontSize: 11,
                letterSpacing: 2,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceLists(ThemeManager tm) {
    return ValueListenableBuilder<List<ScanResult>>(
      valueListenable: _ble.scanResultsNotifier,
      builder: (_, scanResults, __) {
        final known = KnownDevices.instance.all;
        final unknownResults = scanResults
            .where((r) => !KnownDevices.instance.isKnown(r.device.remoteId.str))
            .toList();
        final knownLive = <_KnownEntry>[];
        for (final entry in known) {
          final scan = scanResults
              .where((r) => r.device.remoteId.str == entry.key);
          knownLive.add(_KnownEntry(
            mac: entry.key,
            name: entry.value,
            rssi: scan.isEmpty ? null : scan.first.rssi,
            live: scan.isNotEmpty,
            connected: _ble.isConnected(entry.key),
          ));
        }

        return ListView(
          padding: EdgeInsets.zero,
          children: [
            if (knownLive.isNotEmpty) ...[
              _SectionLabel(text: 'MY DEVICES', tm: tm),
              const SizedBox(height: 10),
              ...knownLive.map((k) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _KnownDeviceCard(
                      entry: k,
                      tm: tm,
                      onTap: () => _connectToKnown(k.mac, k.name),
                      onForget: () => _forgetDevice(k.mac, k.name),
                    ),
                  )),
              const SizedBox(height: 22),
            ],
            _SectionLabel(text: 'OTHER DEVICES', tm: tm),
            const SizedBox(height: 10),
            if (unknownResults.isEmpty)
              _EmptyOtherDevices(tm: tm)
            else
              ...unknownResults.map((r) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ScanResultCard(
                      result: r,
                      tm: tm,
                      onTap: () => _connectToDevice(r.device),
                    ),
                  )),
          ],
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _SectionLabel extends StatelessWidget {
  final String text;
  final ThemeManager tm;
  const _SectionLabel({required this.text, required this.tm});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: TextStyle(
          color: tm.textSub,
          fontSize: 10,
          letterSpacing: 3,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _KnownEntry {
  final String mac;
  final String name;
  final int? rssi;
  final bool live;
  final bool connected;
  _KnownEntry({
    required this.mac,
    required this.name,
    required this.rssi,
    required this.live,
    required this.connected,
  });
}

class _KnownDeviceCard extends StatelessWidget {
  final _KnownEntry entry;
  final ThemeManager tm;
  final VoidCallback onTap;
  final VoidCallback onForget;
  const _KnownDeviceCard(
      {required this.entry,
      required this.tm,
      required this.onTap,
      required this.onForget});

  @override
  Widget build(BuildContext context) {
    final live = entry.live;
    final connected = entry.connected;
    final color = connected
        ? ThemeManager.green
        : live
            ? ThemeManager.cyan
            : tm.textSub;
    return GestureDetector(
      onTap: connected ? null : onTap,
      onLongPress: connected ? null : onForget,
      child: GlassCard(
        borderRadius: 16,
        accent: color,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.15),
                border: Border.all(color: color.withValues(alpha: 0.4)),
              ),
              child: Icon(
                connected
                    ? Icons.check_circle_outline
                    : live
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth,
                color: color,
                size: 16,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    style: TextStyle(
                      color: tm.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        entry.mac,
                        style: TextStyle(
                          color: tm.textSub,
                          fontSize: 10,
                          letterSpacing: 0.6,
                        ),
                      ),
                      if (entry.rssi != null) ...[
                        const SizedBox(width: 10),
                        Text(
                          '${entry.rssi} dBm',
                          style: TextStyle(
                            color: color.withValues(alpha: 0.85),
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: color.withValues(alpha: 0.3)),
              ),
              child: Text(
                connected
                    ? 'LIVE'
                    : live
                        ? 'CONNECT'
                        : 'OUT OF RANGE',
                style: TextStyle(
                  color: color,
                  fontSize: 9,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanResultCard extends StatelessWidget {
  final ScanResult result;
  final ThemeManager tm;
  final VoidCallback onTap;
  const _ScanResultCard(
      {required this.result, required this.tm, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final shownName = bleNameOf(result.device);
    final name = shownName.isEmpty ? 'Unknown Device' : shownName;
    final bars = _rssiBars(result.rssi);

    return GestureDetector(
      onTap: onTap,
      child: GlassCard(
        borderRadius: 16,
        accent: ThemeManager.purple,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              height: 20,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(4, (i) {
                  final active = i < bars;
                  return Container(
                    width: 3.5,
                    height: 5.0 + i * 4,
                    decoration: BoxDecoration(
                      color: active
                          ? ThemeManager.purple
                          : tm.textSub.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(1),
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      color: tm.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        result.device.remoteId.str,
                        style: TextStyle(
                          color: tm.textSub,
                          fontSize: 10,
                          letterSpacing: 0.6,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '${result.rssi} dBm',
                        style: TextStyle(
                          color: ThemeManager.purple.withValues(alpha: 0.85),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                color: tm.textSub.withValues(alpha: 0.6), size: 18),
          ],
        ),
      ),
    );
  }

  int _rssiBars(int rssi) {
    if (rssi >= -60) return 4;
    if (rssi >= -75) return 3;
    if (rssi >= -85) return 2;
    if (rssi >= -95) return 1;
    return 0;
  }
}

class _EmptyOtherDevices extends StatelessWidget {
  final ThemeManager tm;
  const _EmptyOtherDevices({required this.tm});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bluetooth_searching,
              size: 32, color: ThemeManager.purple.withValues(alpha: 0.4)),
          const SizedBox(height: 10),
          Text(
            'Tap the radar to scan',
            style: TextStyle(
              color: tm.textSub,
              fontSize: 11,
              letterSpacing: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
