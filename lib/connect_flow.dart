import 'dart:io';

import 'package:flutter/material.dart';

import 'csv_recorder.dart';
import 'glass.dart';
import 'theme_manager.dart';

// ══════════════════════════════════════════════════════════════════════════
//  connect_flow.dart — the two connect-time questions (ported from the NICU
//  app's connect_flow.dart).
//
//  Call maybeShowConnectDialogs(context, mac: ...) BEFORE
//  BleManager.connect(). It is a complete no-op for a device that has never
//  recorded before. Otherwise:
//
//    "Is this a new patient?"
//      YES (or dismissed) -> fresh recording; the device's stored data is
//                            discarded.
//      NO -> "Continue from last recording?"
//          YES -> CsvRecorder reopens that device's last recording and
//                 backfills it with the data the device stored in its own
//                 memory while the phone was away.
//          NO  -> fresh recording.
//
//  The previous recording is matched by the device's BLE id (the `mac,`
//  line in the CSV). Capnography devices all advertise the same fixed
//  name, so the name cannot tell two units apart; on iOS the id is stable
//  per phone+device (the firmware keeps privacy off).
// ══════════════════════════════════════════════════════════════════════════

Future<void> maybeShowConnectDialogs(
  BuildContext context, {
  required String mac,
}) async {
  // Forget any resume request left over from an earlier attempt for this
  // device that never finished connecting.
  CsvRecorder.instance.clearPendingResume(mac);

  final File? previous = await CsvRecorder.mostRecentRecordingForMac(mac);
  if (previous == null) return; // never recorded before — nothing to ask

  if (!context.mounted) return;
  final isNewPatient = await _askYesNo(
    context,
    title: 'NEW PATIENT?',
    message: 'This device has a previous recording on file:\n\n'
        '${previous.uri.pathSegments.last}\n\nIs this a new patient?',
    yesLabel: 'YES — NEW PATIENT',
    noLabel: 'NO',
    accent: ThemeManager.cyan,
  );
  if (isNewPatient != false) return; // Yes, or dismissed → fresh recording

  if (!context.mounted) return;
  final continueLast = await _askYesNo(
    context,
    title: 'CONTINUE RECORDING?',
    message: 'Continue from the last recording for this device?\n\n'
        'Data recorded on the device while disconnected will be pulled in '
        'automatically.',
    yesLabel: 'YES — CONTINUE',
    noLabel: 'NO — START NEW',
    accent: ThemeManager.green,
  );
  if (continueLast == true) {
    CsvRecorder.instance.markPendingResume(mac, previous);
  }
}

Future<bool?> _askYesNo(
  BuildContext context, {
  required String title,
  required String message,
  required String yesLabel,
  required String noLabel,
  required Color accent,
}) {
  final tm = ThemeManager.instance;
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: GlassCard(
        borderRadius: 26,
        accent: accent,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: accent,
                  fontSize: 11,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                message,
                style: TextStyle(
                  color: tm.textPrimary,
                  fontSize: 13.5,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: GlassPill(
                      onTap: () => Navigator.pop(ctx, false),
                      child: Center(
                        child: Text(noLabel,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: tm.textSub,
                                fontSize: 11,
                                letterSpacing: 1.5,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GlassPill(
                      onTap: () => Navigator.pop(ctx, true),
                      accent: accent,
                      child: Center(
                        child: Text(yesLabel,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: accent,
                                fontSize: 11,
                                letterSpacing: 1.5,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
