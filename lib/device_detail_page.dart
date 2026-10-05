import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

import 'ble_manager.dart';
import 'device_session.dart';
import 'glass.dart';
import 'theme_manager.dart';

// ══════════════════════════════════════════════════════════════════════════
//  DeviceDetailPage — full-screen live view of a single connected device.
//  Reached by tapping a device card on the Monitor page. Auto-closes if
//  the device disconnects while this page is open.
// ══════════════════════════════════════════════════════════════════════════
class DeviceDetailPage extends StatelessWidget {
  final DeviceSession session;
  const DeviceDetailPage({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    const accent = ThemeManager.green;

    return ValueListenableBuilder<List<DeviceSession>>(
      valueListenable: BleManager.instance.sessionsNotifier,
      builder: (_, sessions, __) {
        if (!sessions.any((s) => s.mac == session.mac)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (Navigator.canPop(context)) Navigator.pop(context);
          });
        }
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: LiquidBackground(
            child: SafeArea(
            child: ValueListenableBuilder<int>(
              valueListenable: session.tick,
              builder: (_, __, ___) => Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailHeader(session: session, tm: tm, accent: accent),
                    const SizedBox(height: 22),
                    _BigReading(session: session, tm: tm, accent: accent),
                    const SizedBox(height: 18),
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(
                            flex: 3,
                            child: _FullWaveform(
                                session: session, tm: tm, accent: accent),
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            flex: 2,
                            child: _RmsBreathWaveform(session: session, tm: tm),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    _StatsRow(session: session, tm: tm, accent: accent),
                  ],
                ),
              ),
            ),
          ),
          ),
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _DetailHeader extends StatelessWidget {
  final DeviceSession session;
  final ThemeManager tm;
  final Color accent;
  const _DetailHeader(
      {required this.session, required this.tm, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Row(
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
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: accent.withValues(alpha: 0.4)),
          ),
          child: Text(
            '#${session.slot}',
            style: TextStyle(
              color: accent,
              fontSize: 12,
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
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (session.patient != null)
                Text(
                  session.displayName,
                  style: TextStyle(color: tm.textSub, fontSize: 11),
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
              fontSize: 12,
              letterSpacing: 1.2,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: () => _confirmDisconnect(context),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: ThemeManager.red.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: ThemeManager.red.withValues(alpha: 0.4)),
            ),
            child: const Icon(Icons.power_settings_new,
                color: ThemeManager.red, size: 16),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmDisconnect(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
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
      if (context.mounted) Navigator.pop(context);
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _BigReading extends StatelessWidget {
  final DeviceSession session;
  final ThemeManager tm;
  final Color accent;
  const _BigReading(
      {required this.session, required this.tm, required this.accent});

  @override
  Widget build(BuildContext context) {
    final v = session.currentCo2;
    final intPart = v.floor().toString();
    final tenths = ((v - v.floor()) * 10).floor();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'EtCO₂',
          style: TextStyle(
            color: tm.textSub,
            fontSize: 11,
            letterSpacing: 3,
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
                fontSize: 96,
                fontWeight: FontWeight.w200,
                height: 0.9,
                letterSpacing: -2,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Text(
              '.$tenths',
              style: TextStyle(
                color: accent,
                fontSize: 44,
                fontWeight: FontWeight.w300,
                height: 1.0,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12, left: 8),
              child: Text('%', style: TextStyle(color: tm.textSub, fontSize: 20)),
            ),
          ],
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  Same auto-ranging + clipping as the monitor card's mini waveform, just
//  bigger and with a left axis so the full-screen view reads like a real
//  bedside monitor trace.
// ══════════════════════════════════════════════════════════════════════════
class _FullWaveform extends StatelessWidget {
  final DeviceSession session;
  final ThemeManager tm;
  final Color accent;
  const _FullWaveform(
      {required this.session, required this.tm, required this.accent});

  @override
  Widget build(BuildContext context) {
    final pts = session.points;
    final range = autoCo2Range(pts.map((p) => p.y));
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(6, 16, 16, 10),
      decoration: BoxDecoration(
        color: tm.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
      ),
      child: LineChart(
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
                          fontSize: 12,
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
          titlesData: FlTitlesData(
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 32,
                interval: (range.maxY - range.minY) / 4,
                getTitlesWidget: (v, _) => Text(
                  v.toStringAsFixed(0),
                  style: TextStyle(
                    color: tm.textSub,
                    fontSize: 9,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: pts.isEmpty ? [const FlSpot(0, 0)] : pts.toList(),
              isCurved: true,
              preventCurveOverShooting: true,
              curveSmoothness: 0.25,
              color: accent,
              barWidth: 2.2,
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
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  Mic RMS waveform, colored by the on-device breath_flag: blue while no
//  breath is detected, red for the stretch the firmware flagged as a
//  breath. Gaps between real BLE samples are already backfilled with
//  interpolated points in DeviceSession.addRmsSample, so this just needs
//  to split the run into same-color segments and draw each with a curved
//  line -- the interpolation plus the curve is what keeps it "smooth"
//  instead of a stair-step even though the firmware only notifies every
//  ~5 Hz (every 200 ms).
// ══════════════════════════════════════════════════════════════════════════
class _RmsBreathWaveform extends StatelessWidget {
  final DeviceSession session;
  final ThemeManager tm;
  const _RmsBreathWaveform({required this.session, required this.tm});

  @override
  Widget build(BuildContext context) {
    final pts = session.rmsPoints.toList();
    final flags = session.rmsBreathFlags.toList();
    final borderTone = session.currentBreath ? ThemeManager.redChart : ThemeManager.blue;

    double maxY = 0.0;
    for (final p in pts) {
      if (p.y > maxY) maxY = p.y;
    }
    final rangeMaxY = maxY <= 0 ? 1.0 : maxY * 1.2;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(6, 12, 16, 10),
      decoration: BoxDecoration(
        color: tm.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: borderTone.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'MIC RMS',
                style: TextStyle(
                  color: tm.textSub,
                  fontSize: 10,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              _LegendDot(color: ThemeManager.blue, label: 'quiet'),
              const SizedBox(width: 12),
              _LegendDot(color: ThemeManager.redChart, label: 'breath'),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: pts.length < 2
                ? Center(
                    child: Text(
                      'Waiting for mic data…',
                      style: TextStyle(color: tm.textSub, fontSize: 11),
                    ),
                  )
                : LineChart(
                    LineChartData(
                      minY: 0.0,
                      maxY: rangeMaxY,
                      clipData: const FlClipData.all(),
                      lineTouchData: const LineTouchData(enabled: false),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: rangeMaxY / 3,
                        getDrawingHorizontalLine: (_) => FlLine(
                          color: tm.border,
                          strokeWidth: 0.5,
                          dashArray: const [3, 6],
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: const FlTitlesData(
                        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      ),
                      lineBarsData: _buildSegments(pts, flags),
                    ),
                    duration: Duration.zero,
                  ),
          ),
        ],
      ),
    );
  }

  /// Splits [pts]/[flags] into contiguous same-color runs. Each segment
  /// (after the first) also includes the last point of the previous
  /// segment as its own first point, so the drawn line has no visible gap
  /// at a blue/red transition even though it's rendered as separate
  /// LineChartBarData objects.
  List<LineChartBarData> _buildSegments(List<FlSpot> pts, List<bool> flags) {
    final segments = <LineChartBarData>[];
    int start = 0;
    for (int i = 1; i <= pts.length; i++) {
      final atBoundary = i == pts.length || flags[i] != flags[start];
      if (atBoundary) {
        final segSpots = <FlSpot>[
          if (start > 0) pts[start - 1],
          ...pts.sublist(start, i),
        ];
        segments.add(_lineFor(segSpots, flags[start]));
        start = i;
      }
    }
    return segments;
  }

  LineChartBarData _lineFor(List<FlSpot> spots, bool breath) {
    final color = breath ? ThemeManager.redChart : ThemeManager.blue;
    return LineChartBarData(
      spots: spots,
      isCurved: true,
      preventCurveOverShooting: true,
      curveSmoothness: 0.2,
      color: color,
      barWidth: 2.2,
      isStrokeCapRound: true,
      dotData: const FlDotData(show: false),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: color.withValues(alpha: 0.9),
            fontSize: 9,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _StatsRow extends StatelessWidget {
  final DeviceSession session;
  final ThemeManager tm;
  final Color accent;
  const _StatsRow(
      {required this.session, required this.tm, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _Stat(
            label: 'PEAK',
            value: session.peakCo2.toStringAsFixed(2),
            unit: '%',
            tone: accent,
            tm: tm,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _Stat(
            label: 'BREATH RATE',
            value: session.breathRate.toStringAsFixed(0),
            unit: 'brpm',
            tone: ThemeManager.purple,
            tm: tm,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _Stat(
            label: 'BREATHS',
            value: '${session.breathCount}',
            unit: '',
            tone: ThemeManager.cyan,
            tm: tm,
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String label, value, unit;
  final Color tone;
  final ThemeManager tm;
  const _Stat({
    required this.label,
    required this.value,
    required this.unit,
    required this.tone,
    required this.tm,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      borderRadius: 16,
      accent: tone,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: tone.withValues(alpha: 0.85),
              fontSize: 9,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: TextStyle(
                  color: tm.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 3),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(unit,
                      style: TextStyle(color: tm.textSub, fontSize: 10)),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
