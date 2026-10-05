# Capnography — Real-Time pCO₂ Monitor

A Flutter application for real-time capnography. It connects over Bluetooth Low
Energy (BLE) to optical CO₂ sensors and continuously displays the pCO₂ waveform,
end-tidal peak, breath count, and respiratory rate for up to **8 simultaneous
devices**, archiving every session as CSV.

| | |
|---|---|
| **Display name** | Capnography |
| **Android package** | `com.example.capnography_co2` |
| **iOS bundle ID** | `com.example.capnographyCo2` |
| **Framework** | Flutter 3.44 / Dart 3.12 |
| **Platforms** | Android (deployed) · iOS (project configured, requires macOS to build) |
| **Codebase** | 14 Dart source files · ~7,300 lines |

> A multi-parameter derivative of this application — tracking pO₂, pCO₂, and
> temperature simultaneously — is maintained alongside it at
> `../../NICU-App/`. Both share the same layered architecture, storage
> engine, and UI system.

---

## 1. Capabilities

- **Multi-device monitoring** — up to 8 concurrent BLE sensors, each with an
  independent session, waveform buffer, and recording.
- **Live capnogram** — auto-ranging pCO₂ waveform with tap-to-inspect value
  tooltips, plus peak (EtCO₂), breath count, and respiratory rate.
- **QR provisioning** — scan a device QR code to connect instantly and attach
  patient metadata; scan a material QR to annotate a recording.
- **Automatic recording** — a CSV session starts on connect and is archived on
  disconnect, with no user action required.
- **Tiered data protection** — per-row disk flush, crash recovery, a 30-day
  trash, and automatic mirroring to public storage that survives app uninstall.
- **Session management** — search, rename, annotate, multi-select, batch export
  (system share sheet), batch save-to-device, and batch delete.
- **Liquid Glass interface** — translucent layered UI with light/dark theming.

---

## 2. Hardware Interface

Two sensor variants are supported and detected automatically by payload length.

| Variant | Packet | Contents |
|---|---|---|
| Virtual ESP32 test rig | 24 bytes plaintext | 6 × `float32`, little-endian |
| Production NICU_MINI_BLE | 32 bytes | AES-128-ECB with PKCS#7; decrypts to the same 24-byte payload |

In both cases the float layout is:

```
[phase_diff, mag_ratio, pCO2_ratio, temperature, PD_405, PD_470]
```

This application consumes **index 2 (`pCO2_ratio`)** only; the remaining channels
are ignored. Values are clamped to the range `0.0 – 50.0`.

| Property | Value |
|---|---|
| Known service UUIDs | `abcdef01-…` (production), `12345678-…` (virtual rig) |
| Fallback discovery | Any custom service exposing a notify characteristic |
| AES key | 16 bytes, derived from the firmware key schedule (see `ble_manager.dart`) |

> To consume a different channel, change `kCo2FloatIndex` in
> `lib/ble_manager.dart`. No other code depends on the choice.

> **Calibration status.** The reported value is an **uncalibrated ratiometric
> quantity**, not a calibrated partial pressure. Mapping it to mmHg or percent
> requires a calibration curve derived from reference gases.

---

## 3. Architecture

The application is organised into four layers. Each layer depends only on the
layers below it, which is what allowed the multi-parameter sibling application
to reuse the storage, charting, and BLE infrastructure unchanged.

```
+-----------------------------------------------------------+
|  4. Presentation    main | monitor | device_detail |       |
|                     history | trash | ble | scan_qr        |
|                     glass.dart | theme_manager.dart        |
+-----------------------------------------------------------+
|  3. Persistence     csv_recorder | backup_store |          |
|                     session_metadata                       |
+-----------------------------------------------------------+
|  2. Session state   device_session  (one per device)       |
+-----------------------------------------------------------+
|  1. Transport       ble_manager  (scan | connect | decode) |
+-----------------------------------------------------------+
                             ^
                       CO₂ sensor (BLE)
```

### Data flow

```
BLE notification (24 B plain / 32 B AES)
        |
        v
BleManager._onBytes  ->  decrypt if needed  ->  read float[kCo2FloatIndex]
        |
        +--> DeviceSession.addSample()  -> waveform, peak, breath detection
        |                                          |
        |                                          v
        |                                   UI rebuilds only the affected card
        |
        +--> sampleStream -> CsvRecorder -> one CSV row, flushed immediately
```

State propagation uses `ValueNotifier` and `ValueListenableBuilder`. Each session
owns its own `tick` notifier, so an incoming packet rebuilds **only that
device's** widgets — the reason 8 concurrent devices render without jank.

### Source map

| File | Responsibility |
|---|---|
| `ble_manager.dart` | BLE scanning, connection lifecycle, device cap, AES decryption, packet decoding, `SampleEvent` broadcast. Defines `kCo2FloatIndex`, `kMaxDevices`, and the chart range helper `autoCo2Range()` |
| `device_session.dart` | Per-device runtime state: waveform buffer, current and peak pCO₂, threshold-based breath detection, elapsed clock, tick notifier |
| `csv_recorder.dart` | Session recording, archival, crash recovery, trash lifecycle, CSV parsing |
| `backup_store.dart` | Public-storage mirroring and permission handling |
| `session_metadata.dart` | JSON sidecar for titles, notes, and material info |
| `main.dart` | Application entry, theming, home screen |
| `monitor_page.dart` | Connected-device list with per-device readout and mini waveform |
| `device_detail_page.dart` | Per-device view: large readout, full waveform, peak / rate / breath statistics |
| `history_page.dart` | Session archive, search, multi-select, batch actions, recording detail with chart |
| `trash_page.dart` | 30-day trash: restore, permanent delete, empty |
| `ble_page.dart` | Device scanning and pairing UI, known-device list |
| `scan_qr_page.dart` | Camera QR scanning (device and material modes) |
| `glass.dart` | Liquid Glass design system: `GlassCard`, `GlassPill`, `LiquidBackground` |
| `theme_manager.dart` | Light and dark palettes, accent colours |

---

## 4. Data Protection

Recording integrity is treated as the primary requirement of the system.

| Failure mode | Mitigation |
|---|---|
| Application crash or process kill | Every CSV row is flushed to disk immediately on write |
| Recording interrupted mid-session | Orphaned `__pending.csv` files are detected and finalised at next launch |
| Accidental deletion | Deletions are soft — items are retained in trash for **30 days** and can be restored |
| Application uninstall or device change | Each completed recording is mirrored to public storage (see below) |
| Concurrent sessions overwriting each other | Filenames embed a per-device MAC tag plus a uniqueness guard |

### Public-storage mirror

Completed recordings are copied to:

```
Documents/CO2 Monitor/
```

Files in this directory persist after the application is uninstalled. This
requires the **All files access** permission, which is requested the first time
Save is used. Until it is granted, mirroring silently no-ops and only the
private in-app copy exists.

### Concurrent-session file naming

```
CAPNO_<patient>_<macTag>_<startStamp>__<endStamp>.csv
        |          |         |             +-- YYYYMMDD_HHMMSS
        |          |         +---------------- YYYYMMDD_HHMMSS
        |          +-------------------------- last 4 hex digits of device MAC
        +------------------------------------- patient slug, or devN
```

The MAC tag guarantees that two sensors sharing a patient name and starting in
the same second cannot produce the same filename. A `-2`, `-3` counter is
appended to the prefix as a further guard. Because the counter precedes the
timestamps, the archive's filename-based time parsing is unaffected.

---

## 5. CSV Format

Recordings are stored in the application documents directory under
`capnography_records/`.

```
# Capnography Session
mac,<device MAC>
slot,<display slot>
start_iso,<ISO 8601>
end_iso,<ISO 8601>
name_meta,<optional, from QR>
patient_meta,<optional>
age_meta,<optional>
note_meta,<optional>
---
elapsed,co2_percent
00:00:01.234,3.4210
```

Each data row contains an elapsed timestamp and the pCO₂ value to four decimal
places.

---

## 6. Configuration Reference

Behaviour is controlled by a small set of named constants.

| Setting | File | Symbol |
|---|---|---|
| Maximum concurrent devices | `lib/ble_manager.dart` | `kMaxDevices` (8) |
| Source channel in the payload | `lib/ble_manager.dart` | `kCo2FloatIndex` (2) |
| Default chart bounds | `lib/ble_manager.dart` | `kCo2MinY` (0.0), `kCo2MaxY` (8.0) |
| Accepted service UUIDs | `lib/ble_manager.dart` | `_knownServiceUuids` |
| Waveform history depth | `lib/device_session.dart` | `maxPoints` (300) |
| Breath detection thresholds | `lib/device_session.dart` | `_hi` (0.5), `_lo` (0.3) |
| Trash retention | `lib/csv_recorder.dart` | `kTrashRetentionDays` (30) |
| Public backup folder | `lib/backup_store.dart` | `folderName` |
| Theme palette | `lib/theme_manager.dart` | `static const Color` definitions |
| Application display name | `android/app/src/main/AndroidManifest.xml` | `android:label` |

---

## 7. Build and Run

Prerequisites: Flutter 3.44 or later, the Android SDK, and Xcode for iOS builds.

```bash
flutter pub get
```

### Android

```bash
flutter run                     # deploy to a connected device (hot reload enabled)
flutter build apk --release     # -> build/app/outputs/flutter-apk/app-release.apk
```

Install and inspect:

```bash
adb install -r app-release.apk        # -r preserves existing recordings
adb logcat | grep BLE                 # trace decoded sensor packets
```

> **Dropbox-synchronised path.** This repository lives in a Dropbox folder.
> Gradle's file-system watcher conflicts with Dropbox's background syncing and
> aborts with `java.io.IOException: Cannot snapshot ...`. This is disabled in
> `android/gradle.properties` via `org.gradle.vfs.watch=false`, and builds run
> normally in place. If a build ever fails with that error again, verify the
> flag is still present, or build from a local mirror outside Dropbox and copy
> the APK back.

### iOS

The iOS project is fully configured: camera and Bluetooth usage descriptions, a
Podfile targeting iOS 13.0 with the required `permission_handler` macros, app
icons, and bundle identifier. Compilation requires macOS.

```bash
flutter pub get
cd ios && pod install && cd ..
flutter run                     # simulator (no Apple account) or device (free Apple ID)
```

See `../../iOS-build-guide.md` for the full procedure, including cloud-macOS
options.

### Icons

Source artwork lives in `assets/icon/`. After replacing it:

```bash
dart run flutter_launcher_icons   # regenerates Android and iOS icon sets
```

---

## 8. Testing

```bash
flutter analyze                   # static analysis
flutter test                      # unit and widget tests
```

---

## 9. Dependencies

| Package | Purpose |
|---|---|
| `flutter_blue_plus` | BLE scanning, connection, notifications |
| `fl_chart` | Real-time and historical line charts |
| `mobile_scanner` 7.x | Camera QR scanning |
| `permission_handler` | Bluetooth, camera, and storage permissions |
| `pointycastle` | AES-128 decryption for production sensor packets |
| `path_provider` | Platform storage locations |
| `share_plus` | System share sheet for CSV export |
| `shared_preferences` | Known-device persistence |
| `google_fonts`, `intl`, `open_file`, `cupertino_icons` | Typography, formatting, file handling, iconography |

> `mobile_scanner` was upgraded from 5.2.3 to 7.x to resolve a native
> null-pointer crash in the camera pipeline on Android 16.

---

## 10. Tooling

QR-code generators for printable device and material labels are maintained in
`../QRCode/`:

| Script | Output |
|---|---|
| `Generate_QR.py` | Device QR for the virtual ESP32 test rig |
| `Generate_Capnography_MINI_QR.py` | Device QR for the production NICU_MINI_BLE sensor |
| `QRcode_materials/Generate_Material_QR.py` | Material or consumable QR for annotating recordings |

```bash
pip install qrcode pillow
python Generate_Capnography_MINI_QR.py
```

Set the target MAC address in the script before generating production labels.

---

## 11. Known Limitations and Roadmap

- **Uncalibrated units** — the displayed value is a raw ratiometric quantity;
  a calibration mapping to clinical units is outstanding.
- **Breath detection** uses a simple hysteresis threshold (rising above 0.5
  counts a breath, falling below 0.3 rearms). It is indicative only.
- **Concurrency ceiling** — the 8-device limit reflects Android BLE link
  scheduling reliability rather than device performance.
- **Uninstall protection** requires the user to grant All files access.
- Planned: unit calibration, configurable threshold alarms, time-based chart
  axes, and cloud backup.

---

## 12. Notice

This software is intended for research and engineering evaluation. It is not a
certified medical device and must not be used as the basis for clinical
decisions.
