import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'csv_recorder.dart';
import 'glass.dart';
import 'session_metadata.dart';
import 'theme_manager.dart';

// ══════════════════════════════════════════════════════════════════════════
//  TrashPage — recycle bin for soft-deleted recordings (30-day retention),
//  styled to match the History archive (dark glassmorphism).
// ══════════════════════════════════════════════════════════════════════════
class TrashPage extends StatefulWidget {
  const TrashPage({super.key});
  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  List<_TrashItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final trashed = await CsvRecorder.listTrash();
    final items = <_TrashItem>[];
    for (final t in trashed) {
      final name = await SessionMetadata.instance.getName(t.trashName);
      items.add(_TrashItem(info: t, customName: name));
    }
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _restore(_TrashItem item) async {
    await CsvRecorder.restoreFromTrash(item.info.file);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Recording restored'),
      backgroundColor: ThemeManager.green,
      duration: Duration(seconds: 2),
    ));
  }

  Future<void> _delete(_TrashItem item) async {
    final confirmed = await _confirmDialog(
      title: 'DELETE FOREVER',
      message: item.displayName,
      sub: 'This permanently removes the recording. It cannot be undone.',
      action: 'DELETE',
      actionColor: ThemeManager.red,
    );
    if (confirmed == true) {
      await CsvRecorder.permanentlyDelete(item.info.file);
      await _load();
    }
  }

  Future<void> _empty() async {
    final confirmed = await _confirmDialog(
      title: 'EMPTY TRASH',
      message: 'Delete all ${_items.length} item(s) in Trash?',
      sub: 'This permanently removes every trashed recording.',
      action: 'EMPTY',
      actionColor: ThemeManager.red,
    );
    if (confirmed == true) {
      await CsvRecorder.emptyTrash();
      await _load();
    }
  }

  Future<bool?> _confirmDialog({
    required String title,
    required String message,
    required String sub,
    required String action,
    required Color actionColor,
  }) async {
    final tm = ThemeManager.instance;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        child: GlassCard(
          borderRadius: 26,
          accent: actionColor,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: actionColor,
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
                  fontSize: 13,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 6),
              Text(sub, style: TextStyle(color: tm.textSub, fontSize: 12)),
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
                      child: Text(action,
                          style: TextStyle(
                              color: actionColor,
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
              Expanded(child: _buildList(tm)),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ThemeManager tm) {
    final canEmpty = !_loading && _items.isNotEmpty;
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
        const Text(
          'TRASH',
          style: TextStyle(
            color: ThemeManager.orange,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 3.5,
          ),
        ),
        // "Empty" action — only when there is something to empty.
        canEmpty
            ? GestureDetector(
                onTap: _empty,
                child: GlassCard(
                  borderRadius: 13,
                  accent: ThemeManager.red,
                  elevated: false,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: SizedBox(
                    height: 38,
                    child: Center(
                      child: Text(
                        'EMPTY',
                        style: TextStyle(
                          color: ThemeManager.red.withValues(alpha: 0.9),
                          fontSize: 10,
                          letterSpacing: 2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              )
            : const SizedBox(width: 38, height: 38),
      ],
    );
  }

  Widget _buildList(ThemeManager tm) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 1.6, color: ThemeManager.orange),
            ),
            const SizedBox(height: 14),
            Text(
              'Loading trash…',
              style: TextStyle(color: tm.textSub, fontSize: 12),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.delete_outline,
              size: 48,
              color: ThemeManager.orange.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              'TRASH IS EMPTY',
              style: TextStyle(
                color: tm.textSub,
                fontSize: 11,
                letterSpacing: 3,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Deleted recordings are kept for '
              '${CsvRecorder.kTrashRetentionDays} days.',
              style: TextStyle(color: tm.textSub, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: _items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _TrashCard(
        item: _items[i],
        tm: tm,
        onRestore: () => _restore(_items[i]),
        onDelete: () => _delete(_items[i]),
      ),
    );
  }
}

class _TrashItem {
  final TrashedRecording info;
  final String customName;
  _TrashItem({required this.info, required this.customName});

  /// Title: custom name → formatted recording date → original filename.
  String get displayName {
    if (customName.isNotEmpty) return customName;
    final start = info.startTime;
    if (start != null) {
      return DateFormat('yyyy-MM-dd  HH:mm:ss').format(start);
    }
    return info.originalName;
  }
}

class _TrashCard extends StatelessWidget {
  final _TrashItem item;
  final ThemeManager tm;
  final VoidCallback onRestore, onDelete;
  const _TrashCard({
    required this.item,
    required this.tm,
    required this.onRestore,
    required this.onDelete,
  });

  String _fmt(DateTime? dt) =>
      dt == null ? '—' : DateFormat('yyyy-MM-dd  HH:mm:ss').format(dt);

  @override
  Widget build(BuildContext context) {
    final info = item.info;
    final days = info.daysLeft;
    final urgent = days <= 3;
    final badgeColor = urgent ? ThemeManager.red : ThemeManager.orange;
    return GlassCard(
      borderRadius: 18,
      padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 60,
                decoration: BoxDecoration(
                  color: ThemeManager.orange.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.displayName,
                      style: TextStyle(
                        color: tm.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.play_arrow,
                            color: ThemeManager.green.withValues(alpha: 0.8),
                            size: 11),
                        const SizedBox(width: 4),
                        Text(
                          _fmt(info.startTime),
                          style: TextStyle(
                            color: tm.textPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            fontFeatures:
                                const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(Icons.stop,
                            color: ThemeManager.red.withValues(alpha: 0.7),
                            size: 10),
                        const SizedBox(width: 4),
                        Text(
                          _fmt(info.endTime),
                          style: TextStyle(
                            color: tm.textSub,
                            fontSize: 11,
                            fontFeatures:
                                const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      info.sizeLabel,
                      style: TextStyle(
                        color: ThemeManager.cyan.withValues(alpha: 0.85),
                        fontSize: 10,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              // "N days left" badge
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: badgeColor.withValues(alpha: 0.4)),
                ),
                child: Column(
                  children: [
                    Text(
                      '$days',
                      style: TextStyle(
                        color: badgeColor,
                        fontSize: 18,
                        height: 1.0,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      days == 1 ? 'DAY LEFT' : 'DAYS LEFT',
                      style: TextStyle(
                        color: badgeColor.withValues(alpha: 0.9),
                        fontSize: 7,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  icon: Icons.restore,
                  label: 'RESTORE',
                  color: ThemeManager.green,
                  tm: tm,
                  onTap: onRestore,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionButton(
                  icon: Icons.delete_forever,
                  label: 'DELETE',
                  color: ThemeManager.red,
                  tm: tm,
                  onTap: onDelete,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final ThemeManager tm;
  final VoidCallback onTap;
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.tm,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 38,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 15),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 10,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
