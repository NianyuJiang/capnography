// ════════════════════════════════════════════════════════════════════════
//  monitor_page.dart
//  Confidence: HIGH for this specific version — verbatim from this
//  conversation. ⚠️ NOTE: This is the SINGLE-CHANNEL version that only
//  displays pCO2 (floats[2]). The four-channel display (pO2 Lifetime,
//  pO2 Intensity, pCO2 Ratio, Temperature) from the very first version
//  of the app was simplified to single-channel during the multi-device
//  refactor. If your APK shows 4 channels per card, this file needs
//  expansion — tell me and I'll write the 4-channel version.
// ════════════════════════════════════════════════════════════════════════
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

import 'ble_manager.dart';
import 'device_session.dart';
import 'device_detail_page.dart';
import 'glass.dart';
import 'theme_manager.dart';

class MonitorPage extends StatelessWidget {
  const MonitorPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LiquidBackground(
        child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Header(),
              const SizedBox(height: 16),
              Expanded(
                child: ValueListenableBuilder<List<DeviceSession>>(
                  valueListenable: BleManager.instance.sessionsNotifier,
                  builder: (_, sessions, __) {
                    if (sessions.isEmpty) return const _EmptyState();
                    return _SessionList(sessions: sessions);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
        Column(
          children: [
            const Text(
              'CO₂ MONITOR',
              style: TextStyle(
                color: ThemeManager.green,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 3.5,
              ),
            ),
            const SizedBox(height: 2),
            ValueListenableBuilder<List<DeviceSession>>(
              valueListenable: BleManager.instance.sessionsNotifier,
              builder: (_, sessions, __) => Text(
                '${sessions.length}/$kMaxDevices devices',
                style: TextStyle(
                  color: tm.textSub,
                  fontSize: 11,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(width: 38),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.monitor_heart_outlined,
              size: 56, color: ThemeManager.green.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          Text(
            'NO DEVICES CONNECTED',
            style: TextStyle(
              color: tm.textSub,
              fontSize: 12,
              letterSpacing: 3,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Scan a QR code or open the Bluetooth page\nto connect up to $kMaxDevices sensors.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: tm.textSub,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _SessionList extends StatelessWidget {
  final List<DeviceSession> sessions;
  const _SessionList({required this.sessions});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: sessions.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) => _DeviceCard(session: sessions[i]),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  One card per device. Listens to its own session's tick notifier so
//  multiple devices don't trigger each other's rebuilds.
// ══════════════════════════════════════════════════════════════════════════
class _DeviceCard extends StatelessWidget {
  final DeviceSession session;
  const _DeviceCard({required this.session});

  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    const accent = ThemeManager.green;

    // GlassCard sits OUTSIDE the per-tick ValueListenableBuilder so its
    // BackdropFilter blur isn't re-run on every BLE sample — only the
    // Column below rebuilds live.
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DeviceDetailPage(session: session),
        ),
      ),
      child: GlassCard(
        accent: accent,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: ValueListenableBuilder<int>(
          valueListenable: session.tick,
          builder: (_, __, ___) {
            final v = session.currentCo2;
            final intPart = v.floor().toString();
            final tenths = ((v - v.floor()) * 10).floor();

            return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Top bar: slot + patient + disconnect ──
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: accent.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      '#${session.slot}',
                      style: const TextStyle(
                        color: accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session.patient ?? session.displayName,
                          style: TextStyle(
                            color: tm.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (session.patient != null)
                          Text(
                            session.displayName,
                            style: TextStyle(
                              color: tm.textSub,
                              fontSize: 10,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  ValueListenableBuilder<String>(
                    valueListenable: session.elapsedNotifier,
                    builder: (_, e, __) => Text(
                      e,
                      style: TextStyle(
                        color: tm.textSub,
                        fontSize: 11,
                        letterSpacing: 1.2,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: () => _confirmDisconnect(context),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: ThemeManager.red.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: ThemeManager.red.withValues(alpha: 0.4)),
                      ),
                      child: const Icon(Icons.power_settings_new,
                          color: ThemeManager.red, size: 14),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // ── Reading + chart row ──
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Reading
                  SizedBox(
                    width: 110,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'EtCO₂',
                          style: TextStyle(
                            color: tm.textSub,
                            fontSize: 9,
                            letterSpacing: 2,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              intPart,
                              style: TextStyle(
                                color: tm.textPrimary,
                                fontSize: 46,
                                fontWeight: FontWeight.w200,
                                height: 0.95,
                                letterSpacing: -1.5,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                            Text(
                              '.$tenths',
                              style: const TextStyle(
                                color: accent,
                                fontSize: 24,
                                fontWeight: FontWeight.w300,
                                height: 1.0,
                                fontFeatures: [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                            const SizedBox(width: 4),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '%',
                                style: TextStyle(
                                  color: tm.textSub,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Mini waveform
                  Expanded(
                    child: SizedBox(
                      height: 86,
                      child: _MiniWaveform(session: session, accent: accent),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // ── Peak readout ──
              Row(
                children: [
                  _MiniStat(
                    label: 'PEAK',
                    value: session.peakCo2.toStringAsFixed(2),
                    unit: '%',
                    tone: accent,
                    tm: tm,
                  ),
                ],
              ),
            ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _confirmDisconnect(BuildContext context) async {
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
                'DISCONNECT DEVICE',
                style: TextStyle(
                  color: ThemeManager.red,
                  fontSize: 11,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '#${session.slot} · ${session.patient ?? session.displayName}',
                style: TextStyle(
                  color: tm.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'The current recording will be saved to history.',
                style: TextStyle(color: tm.textSub, fontSize: 12),
              ),
              const SizedBox(height: 20),
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
                      child: const Text('DISCONNECT',
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
      await BleManager.instance.disconnect(session.mac);
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _MiniWaveform extends StatelessWidget {
  final DeviceSession session;
  final Color accent;
  const _MiniWaveform({required this.session, required this.accent});

  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    final pts = session.points;
    final range = autoCo2Range(pts.map((p) => p.y));
    return LineChart(
      LineChartData(
        minY: range.minY,
        maxY: range.maxY,
        clipData: const FlClipData.all(),
        lineTouchData: LineTouchData(
          enabled: true,
          handleBuiltInTouches: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => Colors.black.withValues(alpha: 0.82),
            tooltipRoundedRadius: 8,
            getTooltipItems: (spots) => spots
                .map((s) => LineTooltipItem(
                      '${s.y.toStringAsFixed(2)} %',
                      const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ))
                .toList(),
          ),
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: (range.maxY - range.minY) / 4,
          getDrawingHorizontalLine: (_) => FlLine(
            color: tm.border,
            strokeWidth: 0.5,
            dashArray: const [3, 6],
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: const FlTitlesData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: pts.isEmpty ? [const FlSpot(0, 0)] : pts.toList(),
            isCurved: true,
            preventCurveOverShooting: true,
            curveSmoothness: 0.25,
            color: accent,
            barWidth: 1.8,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  accent.withValues(alpha: 0.22),
                  accent.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ],
      ),
      duration: Duration.zero,
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label, value, unit;
  final Color tone;
  final ThemeManager tm;
  const _MiniStat({
    required this.label,
    required this.value,
    required this.unit,
    required this.tone,
    required this.tm,
  });
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          label,
          style: TextStyle(
            color: tone.withValues(alpha: 0.85),
            fontSize: 9,
            letterSpacing: 2,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          value,
          style: TextStyle(
            color: tm.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 1),
        Text(
          unit,
          style: TextStyle(color: tm.textSub, fontSize: 10),
        ),
      ],
    );
  }
}
