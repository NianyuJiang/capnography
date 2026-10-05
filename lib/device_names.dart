import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// ══════════════════════════════════════════════════════════════════════════
//  device_names.dart — the name a sensor is ADVERTISING right now.
//
//  On iOS, BluetoothDevice.platformName is the name CoreBluetooth has
//  CACHED for that Bluetooth address, which can be an OLD name: a board
//  reflashed with a new device name keeps showing the previous one.
//  The advertising packet itself always carries the current name, so every
//  scan result's advertised name is remembered here (by device id), and
//  bleNameOf() prefers it over the cached platformName.
// ══════════════════════════════════════════════════════════════════════════

final Map<String, String> _advNames = {};

/// Remember the advertised names in these scan results. Called by every
/// scan listener in BleManager.
void noteScanResults(Iterable<ScanResult> results) {
  for (final r in results) {
    final n = r.advertisementData.advName.trim();
    if (n.isNotEmpty) _advNames[r.device.remoteId.str] = n;
  }
}

/// Best current name for [d]: its advertised name if one has been seen,
/// otherwise iOS/Android's platformName. Always trimmed; may be empty.
String bleNameOf(BluetoothDevice d) {
  final adv = _advNames[d.remoteId.str];
  if (adv != null && adv.isNotEmpty) return adv;
  return d.platformName.trim();
}
