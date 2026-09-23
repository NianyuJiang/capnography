import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import 'backup_store.dart';
import 'ble_manager.dart';
import 'csv_recorder.dart';
import 'glass.dart';
import 'scan_qr_page.dart';
import 'session_metadata.dart';
import 'theme_manager.dart';
import 'trash_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<_HistoryItem> _items = [];
  bool _loading = true;

  // ── Search state ──
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  // ── Multi-select state ──
  bool _selectionMode = false;
  final Set<String> _selected = {};

  /// Currently-selected items resolved against the full list.
  List<_HistoryItem> get _selectedItems =>
      _items.where((it) => _selected.contains(it.info.name)).toList();

  void _enterSelection() => setState(() => _selectionMode = true);

  void _exitSelection() => setState(() {
        _selectionMode = false;
        _selected.clear();
      });

  void _toggle(_HistoryItem item) => setState(() {
        final key = item.info.name;
        if (!_selected.remove(key)) _selected.add(key);
      });

  void _selectAllOrNone() => setState(() {
        final visible = _visibleItems;
        final allSelected = visible.isNotEmpty &&
            visible.every((it) => _selected.contains(it.info.name));
        if (allSelected) {
          for (final it in visible) {
            _selected.remove(it.info.name);
          }
        } else {
          for (final it in visible) {
            _selected.add(it.info.name);
          }
        }
      });

  Future<void> _batchExport() async {
    final sel = _selectedItems;
    if (sel.isEmpty) return;
    await Share.shareXFiles(
      sel.map((it) => XFile(it.info.file.path)).toList(),
      subject: 'CO2 Monitor recordings',
    );
    if (!mounted) return;
    _exitSelection();
  }

  /// Copy the selected recordings into public device storage so they
  /// survive an uninstall. Asks for all-files access on first use.
  Future<void> _batchSave() async {
    final sel = _selectedItems;
    if (sel.isEmpty) return;
    await _saveFilesToDevice(context, sel.map((it) => it.info.file).toList());
  }

  Future<void> _batchTrash() async {
    final sel = _selectedItems;
    if (sel.isEmpty) return;
    final n = sel.length;
    final confirmed = await _confirmDialog(
      title: 'MOVE TO TRASH',
      message: 'Move $n ${n == 1 ? 'recording' : 'recordings'} to Trash?',
      sub: 'Kept 30 days — you can restore them.',
      action: 'MOVE TO TRASH',
      actionColor: ThemeManager.orange,
    );
    if (confirmed != true) return;
    for (final it in sel) {
      await CsvRecorder.moveToTrash(it.info.file);
    }
    await _load();
    if (!mounted) return;
    _exitSelection();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Moved $n to Trash'),
      backgroundColor: ThemeManager.instance.surface,
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      final q = _searchCtrl.text;
      if (q != _query) setState(() => _query = q);
    });
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final files = await CsvRecorder.listRecordings();
    final items = <_HistoryItem>[];
    for (final f in files) {
      final name = await SessionMetadata.instance.getName(f.name);
      items.add(_HistoryItem(info: f, customName: name));
    }
    // Newest-first by recording start time. Items without a start time
    // (corrupt / unfinished CSV) sink to the bottom.
    items.sort((a, b) {
      final ta = a.info.startTime;
      final tb = b.info.startTime;
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    });
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  /// Items filtered by the current search query.
  /// Matches if [customName] (or "Untitled session" placeholder) starts
  /// with the query, case-insensitive, from the first character.
  List<_HistoryItem> get _visibleItems {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _items;
    return _items
        .where((it) => it.displayName.toLowerCase().startsWith(q))
        .toList();
  }

  Future<void> _delete(_HistoryItem item) async {
    final confirmed = await _confirmDialog(
      title: 'MOVE TO TRASH',
      message: item.displayName,
      sub: 'Kept 30 days — you can restore it.',
      action: 'MOVE TO TRASH',
      actionColor: ThemeManager.orange,
    );
    if (confirmed == true) {
      final originalName = item.info.name;
      await CsvRecorder.moveToTrash(item.info.file);
      // The trashed file lives at a new path; look it up so UNDO can
      // restore exactly this recording.
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Moved to Trash'),
        backgroundColor: ThemeManager.instance.surface,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'UNDO',
          textColor: ThemeManager.cyan,
          onPressed: () async {
            final trashed = await CsvRecorder.listTrash();
            TrashedRecording? match;
            for (final t in trashed) {
              if (t.originalName == originalName) {
                match = t;
                break;
              }
            }
            if (match != null) {
              await CsvRecorder.restoreFromTrash(match.file);
              await _load();
            }
          },
        ),
      ));
    }
  }

  Future<void> _editName(_HistoryItem item) async {
    final result = await _renameDialog(item.customName);
    if (result != null) {
      await SessionMetadata.instance.setName(item.info.name, result);
      _load();
    }
  }

  Future<String?> _renameDialog(String initial) async {
    final tm = ThemeManager.instance;
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        child: GlassCard(
          borderRadius: 26,
          accent: ThemeManager.cyan,
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'EDIT SESSION NAME',
                style: TextStyle(
                  color: ThemeManager.cyan,
                  fontSize: 11,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                style: TextStyle(color: tm.textPrimary, fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'e.g. Patient A — morning test',
                  hintStyle: TextStyle(
                      color: tm.textSub.withValues(alpha: 0.6),
                      fontSize: 13),
                  filled: true,
                  fillColor: tm.bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: tm.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: tm.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                        color: ThemeManager.cyan, width: 1.5),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
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
                      onPressed: () =>
                          Navigator.pop(ctx, controller.text.trim()),
                      child: const Text('SAVE',
                          style: TextStyle(
                              color: ThemeManager.cyan,
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
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26)),
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
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.translucent,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(context, tm),
                const SizedBox(height: 16),
                _buildSearchBar(tm),
                const SizedBox(height: 16),
                _buildStatsBar(tm),
                const SizedBox(height: 18),
                Expanded(child: _buildList(tm)),
                if (_selectionMode) _buildActionBar(tm),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ThemeManager tm) {
    if (_selectionMode) return _buildSelectionHeader(tm);
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
          'ARCHIVE',
          style: TextStyle(
            color: ThemeManager.cyan,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 3.5,
          ),
        ),
        Row(
          children: [
            // Select (multi-select mode)
            GestureDetector(
              onTap: _items.isEmpty ? null : _enterSelection,
              child: GlassCard(
                borderRadius: 13,
                elevated: false,
                child: SizedBox(
                  width: 38,
                  height: 38,
                  child: Icon(Icons.checklist_rounded,
                      color: _items.isEmpty
                          ? tm.textSub.withValues(alpha: 0.4)
                          : tm.textPrimary,
                      size: 16),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Trash / recycle bin
            GestureDetector(
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const TrashPage()),
                );
                _load();
              },
              child: GlassCard(
                borderRadius: 13,
                elevated: false,
                child: SizedBox(
                  width: 38,
                  height: 38,
                  child: Icon(Icons.delete_outline,
                      color: tm.textPrimary, size: 16),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _load,
              child: GlassCard(
                borderRadius: 13,
                elevated: false,
                child: SizedBox(
                  width: 38,
                  height: 38,
                  child: Icon(Icons.refresh, color: tm.textPrimary, size: 16),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSelectionHeader(ThemeManager tm) {
    final visible = _visibleItems;
    final allSelected = visible.isNotEmpty &&
        visible.every((it) => _selected.contains(it.info.name));
    final n = _selected.length;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Cancel
        GestureDetector(
          onTap: _exitSelection,
          child: GlassCard(
            borderRadius: 13,
            elevated: false,
            child: const SizedBox(
              width: 38,
              height: 38,
              child: Icon(Icons.close, color: ThemeManager.cyan, size: 16),
            ),
          ),
        ),
        // Live count
        Text(
          n == 0 ? 'SELECT ITEMS' : '$n SELECTED',
          style: const TextStyle(
            color: ThemeManager.cyan,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 3.5,
          ),
        ),
        // Select all / deselect all
        GestureDetector(
          onTap: _selectAllOrNone,
          child: GlassCard(
            borderRadius: 13,
            accent: ThemeManager.cyan,
            elevated: false,
            child: SizedBox(
              width: 38,
              height: 38,
              child: Icon(
                allSelected
                    ? Icons.remove_done_rounded
                    : Icons.done_all_rounded,
                color: ThemeManager.cyan,
                size: 16,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchBar(ThemeManager tm) {
    final hasText = _query.isNotEmpty;
    return GlassCard(
      borderRadius: 16,
      accent: hasText ? ThemeManager.cyan : null,
      elevated: false,
      child: SizedBox(
        height: 46,
        child: Row(
        children: [
          const SizedBox(width: 14),
          Icon(Icons.search,
              color: hasText
                  ? ThemeManager.cyan
                  : tm.textSub.withValues(alpha: 0.7),
              size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              style: TextStyle(
                color: tm.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              decoration: InputDecoration(
                hintText: 'Search by device name…',
                hintStyle: TextStyle(
                  color: tm.textSub.withValues(alpha: 0.6),
                  fontSize: 13,
                ),
                isCollapsed: true,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 14),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
              cursorColor: ThemeManager.cyan,
              textInputAction: TextInputAction.search,
            ),
          ),
          if (hasText)
            GestureDetector(
              onTap: () {
                _searchCtrl.clear();
                FocusScope.of(context).unfocus();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Icon(Icons.close,
                    color: tm.textSub.withValues(alpha: 0.7), size: 16),
              ),
            )
          else
            const SizedBox(width: 14),
        ],
      ),
      ),
    );
  }

  Widget _buildStatsBar(ThemeManager tm) {
    final visible = _visibleItems;
    final totalBytes =
        visible.fold<int>(0, (s, it) => s + it.info.sizeBytes);
    final totalKb = (totalBytes / 1024).toStringAsFixed(1);
    final isFiltered = _query.trim().isNotEmpty;
    return Row(
      children: [
        _MiniStat(
            label: isFiltered ? 'MATCHING' : 'SESSIONS',
            value: '${visible.length}',
            tm: tm),
        const SizedBox(width: 28),
        _MiniStat(label: 'STORAGE', value: '$totalKb KB', tm: tm),
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
                  strokeWidth: 1.6, color: ThemeManager.cyan),
            ),
            const SizedBox(height: 14),
            Text(
              'Loading recordings…',
              style: TextStyle(color: tm.textSub, fontSize: 12),
            ),
          ],
        ),
      );
    }
    final visible = _visibleItems;
    if (visible.isEmpty) {
      // Distinguish "no recordings at all" from "no matches"
      final isFiltered = _query.trim().isNotEmpty;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isFiltered ? Icons.search_off : Icons.folder_outlined,
              size: 48,
              color: ThemeManager.cyan.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              isFiltered ? 'NO MATCHES' : 'NO RECORDINGS',
              style: TextStyle(
                color: tm.textSub,
                fontSize: 11,
                letterSpacing: 3,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isFiltered
                  ? 'No session name starts with "${_query.trim()}"'
                  : 'Sessions are saved automatically',
              style: TextStyle(color: tm.textSub, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: visible.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _HistoryCard(
        item: visible[i],
        tm: tm,
        selectionMode: _selectionMode,
        selected: _selected.contains(visible[i].info.name),
        onTap: () async {
          if (_selectionMode) {
            _toggle(visible[i]);
            return;
          }
          await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => RecordingChartPage(item: visible[i])),
          );
          _load();
        },
        onLongPress: _selectionMode
            ? null
            : () {
                _enterSelection();
                _toggle(visible[i]);
              },
        onEdit: () => _editName(visible[i]),
        onDelete: () => _delete(visible[i]),
        onShare: () => Share.shareXFiles(
          [XFile(visible[i].info.file.path)],
          subject: visible[i].displayName,
          text: 'CO2 Monitor recording: ${visible[i].displayName}',
        ),
      ),
    );
  }

  /// Bottom action bar (Export / Save / Trash) shown while selecting.
  Widget _buildActionBar(ThemeManager tm) {
    final n = _selected.length;
    final enabled = n > 0;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        children: [
          Expanded(
            child: _actionPill(
              tm,
              enabled: enabled,
              icon: Icons.ios_share,
              label: 'EXPORT',
              tone: ThemeManager.cyan,
              onTap: _batchExport,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _actionPill(
              tm,
              enabled: enabled,
              icon: Icons.download_rounded,
              label: 'SAVE',
              tone: ThemeManager.green,
              onTap: _batchSave,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _actionPill(
              tm,
              enabled: enabled,
              icon: Icons.delete_outline,
              label: 'TRASH',
              tone: ThemeManager.orange,
              onTap: _batchTrash,
            ),
          ),
        ],
      ),
    );
  }

  /// One capsule in the selection action bar. FittedBox keeps the label from
  /// overflowing now that three pills share the row on narrow phones.
  // NOTE: GlassPill is intentionally non-const (theme-reactive).
  Widget _actionPill(
    ThemeManager tm, {
    required bool enabled,
    required IconData icon,
    required String label,
    required Color tone,
    required VoidCallback onTap,
  }) {
    final color = enabled ? tone : tm.textSub.withValues(alpha: 0.5);
    return GlassPill(
      accent: enabled ? tone : null,
      onTap: enabled ? onTap : null,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryItem {
  final RecordingInfo info;
  final String customName;
  _HistoryItem({required this.info, required this.customName});

  String get displayName =>
      customName.isEmpty ? 'Untitled session' : customName;
}

class _MiniStat extends StatelessWidget {
  final String label, value;
  final ThemeManager tm;
  const _MiniStat(
      {required this.label, required this.value, required this.tm});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: tm.textSub,
            fontSize: 9,
            letterSpacing: 2.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: tm.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w400,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final _HistoryItem item;
  final ThemeManager tm;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap, onEdit, onDelete, onShare;
  final VoidCallback? onLongPress;
  const _HistoryCard({
    required this.item,
    required this.tm,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    required this.onShare,
    this.selectionMode = false,
    this.selected = false,
    this.onLongPress,
  });

  String _fmt(DateTime? dt) =>
      dt == null ? '—' : DateFormat('yyyy-MM-dd  HH:mm:ss').format(dt);

  @override
  Widget build(BuildContext context) {
    final info = item.info;
    final untitled = item.customName.isEmpty;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: GlassCard(
        borderRadius: 18,
        accent: selected ? ThemeManager.cyan : null,
        padding: const EdgeInsets.fromLTRB(18, 14, 6, 14),
        child: Row(
          children: [
            if (selectionMode) ...[
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked,
                color: selected
                    ? ThemeManager.cyan
                    : tm.textSub.withValues(alpha: 0.6),
                size: 22,
              ),
              const SizedBox(width: 14),
            ],
            Container(
              width: 3,
              height: 72,
              decoration: BoxDecoration(
                color: ThemeManager.green,
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
                      color: untitled ? tm.textSub : tm.textPrimary,
                      fontSize: 15,
                      fontWeight:
                          untitled ? FontWeight.w400 : FontWeight.w600,
                      fontStyle:
                          untitled ? FontStyle.italic : FontStyle.normal,
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
            if (!selectionMode) ...[
              IconButton(
                onPressed: onEdit,
                icon: Icon(Icons.edit_outlined,
                    color: ThemeManager.cyan.withValues(alpha: 0.85),
                    size: 18),
                splashRadius: 18,
              ),
              IconButton(
                onPressed: onShare,
                icon: Icon(Icons.ios_share, color: tm.textSub, size: 18),
                splashRadius: 18,
              ),
              IconButton(
                onPressed: onDelete,
                icon: Icon(Icons.delete_outline,
                    color: ThemeManager.red.withValues(alpha: 0.7), size: 18),
                splashRadius: 18,
              ),
            ] else
              const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class RecordingChartPage extends StatefulWidget {
  final _HistoryItem item;
  const RecordingChartPage({super.key, required this.item});
  @override
  State<RecordingChartPage> createState() => _RecordingChartPageState();
}

class _RecordingChartPageState extends State<RecordingChartPage> {
  RecordingData? _data;
  bool _loading = true;
  String _customName = '';
  final TextEditingController _notesCtrl = TextEditingController();
  final TextEditingController _materialCtrl = TextEditingController();
  Timer? _saveTimer;
  Timer? _materialSaveTimer;

  @override
  void initState() {
    super.initState();
    _customName = widget.item.customName;
    _load();
  }

  Future<void> _load() async {
    final d = await CsvRecorder.parseFile(widget.item.info.file);
    final notes =
        await SessionMetadata.instance.getNotes(widget.item.info.name);
    final material =
        await SessionMetadata.instance.getMaterial(widget.item.info.name);
    if (!mounted) return;
    setState(() {
      _data = d;
      _notesCtrl.text = notes;
      _materialCtrl.text = material;
      _loading = false;
    });
  }

  void _onNotesChanged() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      SessionMetadata.instance
          .setNotes(widget.item.info.name, _notesCtrl.text);
    });
  }

  void _onMaterialChanged() {
    _materialSaveTimer?.cancel();
    _materialSaveTimer = Timer(const Duration(milliseconds: 600), () {
      SessionMetadata.instance
          .setMaterial(widget.item.info.name, _materialCtrl.text);
    });
  }

  /// Copy THIS recording into public device storage (Documents/<folder>)
  /// so it is still there after the app is uninstalled.
  Future<void> _saveToDevice() async {
    await _saveFilesToDevice(context, [widget.item.info.file]);
  }

  Future<void> _scanMaterial() async {
    final scanned = await ScanQRPage.pickMaterial(context);
    if (scanned == null || scanned.isEmpty) return;
    if (!mounted) return;
    // Overwrite previous material info (per the chosen UX)
    setState(() => _materialCtrl.text = scanned);
    await SessionMetadata.instance
        .setMaterial(widget.item.info.name, scanned);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Material info updated'),
      backgroundColor: ThemeManager.green,
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _editName() async {
    final tm = ThemeManager.instance;
    final controller = TextEditingController(text: _customName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26)),
        child: GlassCard(
          borderRadius: 26,
          accent: ThemeManager.cyan,
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'EDIT SESSION NAME',
                style: TextStyle(
                  color: ThemeManager.cyan,
                  fontSize: 11,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                style: TextStyle(color: tm.textPrimary, fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'e.g. Patient A — morning test',
                  hintStyle: TextStyle(
                      color: tm.textSub.withValues(alpha: 0.6),
                      fontSize: 13),
                  filled: true,
                  fillColor: tm.bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: tm.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: tm.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                        color: ThemeManager.cyan, width: 1.5),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
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
                      onPressed: () =>
                          Navigator.pop(ctx, controller.text.trim()),
                      child: const Text('SAVE',
                          style: TextStyle(
                              color: ThemeManager.cyan,
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
    if (result != null) {
      await SessionMetadata.instance.setName(widget.item.info.name, result);
      setState(() => _customName = result);
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _materialSaveTimer?.cancel();
    SessionMetadata.instance
        .setNotes(widget.item.info.name, _notesCtrl.text);
    SessionMetadata.instance
        .setMaterial(widget.item.info.name, _materialCtrl.text);
    _notesCtrl.dispose();
    _materialCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    final hasMaterial = _materialCtrl.text.trim().isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LiquidBackground(
        child: SafeArea(
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.translucent,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(context, tm),
                const SizedBox(height: 20),
                _buildNameBlock(tm),
                const SizedBox(height: 14),
                _buildMeta(tm),
                const SizedBox(height: 16),
                _buildSummaryRow(tm),
                const SizedBox(height: 16),
                SizedBox(height: 280, child: _buildChart(tm)),
                if (hasMaterial) ...[
                  const SizedBox(height: 16),
                  _buildMaterial(tm),
                ],
                const SizedBox(height: 16),
                _buildNotes(tm),
                const SizedBox(height: 24),
              ],
            ),
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
              'SESSION',
              style: TextStyle(
                color: ThemeManager.green,
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
            // 📷 Scan material QR
            GestureDetector(
              onTap: _scanMaterial,
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
                    'Scan material',
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
            // ⬇ Save a copy to public device storage (survives uninstall)
            GestureDetector(
              onTap: _saveToDevice,
              child: GlassCard(
                borderRadius: 13,
                elevated: false,
                accent: ThemeManager.green,
                child: const SizedBox(
                  width: 38,
                  height: 38,
                  child: Icon(Icons.download_rounded,
                      color: ThemeManager.green, size: 17),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Share / open CSV
            GestureDetector(
              onTap: () => Share.shareXFiles(
                [XFile(widget.item.info.file.path)],
                subject: widget.item.displayName,
                text: 'CO2 Monitor recording: ${widget.item.displayName}',
              ),
              child: GlassCard(
                borderRadius: 13,
                elevated: false,
                child: SizedBox(
                  width: 38,
                  height: 38,
                  child:
                      Icon(Icons.ios_share, color: tm.textPrimary, size: 14),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildNameBlock(ThemeManager tm) {
    final untitled = _customName.isEmpty;
    final display = untitled ? 'Untitled session' : _customName;
    return GestureDetector(
      onTap: _editName,
      child: GlassCard(
        borderRadius: 18,
        accent: ThemeManager.cyan,
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'NAME',
                    style: TextStyle(
                      color: tm.textSub,
                      fontSize: 9,
                      letterSpacing: 2.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    display,
                    style: TextStyle(
                      color: untitled ? tm.textSub : tm.textPrimary,
                      fontSize: 16,
                      fontWeight: untitled
                          ? FontWeight.w400
                          : FontWeight.w600,
                      fontStyle:
                          untitled ? FontStyle.italic : FontStyle.normal,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.edit_outlined,
                color: ThemeManager.cyan.withValues(alpha: 0.85),
                size: 18),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildMeta(ThemeManager tm) {
    final start = widget.item.info.startTime;
    final end = widget.item.info.endTime;
    final fmt = DateFormat('yyyy-MM-dd HH:mm:ss');
    return SizedBox(
      width: double.infinity,
      child: GlassCard(
        borderRadius: 18,
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.play_arrow, color: ThemeManager.green, size: 12),
              const SizedBox(width: 4),
              Text(
                start == null ? '—' : fmt.format(start),
                style: TextStyle(
                  color: tm.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.stop, color: ThemeManager.red, size: 12),
              const SizedBox(width: 4),
              Text(
                end == null ? '—' : fmt.format(end),
                style: TextStyle(
                  color: tm.textSub,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildSummaryRow(ThemeManager tm) {
    final d = _data;
    final peak = d?.peak.toStringAsFixed(2) ?? '—';
    final mean = d?.mean.toStringAsFixed(2) ?? '—';
    final samples = d?.samples.length.toString() ?? '—';
    return Row(
      children: [
        Expanded(
          child: _SummaryStat(
              label: 'PEAK',
              value: peak,
              unit: '%',
              tone: ThemeManager.green,
              tm: tm),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SummaryStat(
              label: 'MEAN',
              value: mean,
              unit: '%',
              tone: ThemeManager.cyan,
              tm: tm),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SummaryStat(
              label: 'SAMPLES',
              value: samples,
              unit: '',
              tone: ThemeManager.purple,
              tm: tm),
        ),
      ],
    );
  }

  Widget _buildChart(ThemeManager tm) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 1.6, color: ThemeManager.green),
            ),
            const SizedBox(height: 14),
            Text(
              'Loading chart…',
              style: TextStyle(color: tm.textSub, fontSize: 12),
            ),
          ],
        ),
      );
    }
    final d = _data;
    if (d == null || d.samples.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: tm.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: tm.border),
        ),
        child: Center(
          child: Text('No data',
              style: TextStyle(color: tm.textSub, fontSize: 12)),
        ),
      );
    }
    final spots = List<FlSpot>.generate(
        d.samples.length, (i) => FlSpot(i.toDouble(), d.samples[i].co2));
    final range = autoCo2Range(d.samples.map((s) => s.co2));
    final maxY = range.maxY;

    return Container(
      decoration: BoxDecoration(
        color: tm.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tm.border),
      ),
      padding: const EdgeInsets.fromLTRB(8, 18, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Text(
              'pCO₂ WAVEFORM',
              style: TextStyle(
                color: tm.textSub,
                fontSize: 9,
                letterSpacing: 3,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: LineChart(
              LineChartData(
                minY: range.minY,
                maxY: maxY,
                clipData: const FlClipData.all(),
                lineTouchData: LineTouchData(
                  enabled: true,
                  handleBuiltInTouches: true,
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) =>
                        Colors.black.withValues(alpha: 0.82),
                    tooltipRoundedRadius: 8,
                    getTooltipItems: (spots) => spots.map((s) {
                      final idx = s.x.toInt();
                      final t = (idx >= 0 && idx < d.samples.length)
                          ? d.samples[idx].elapsedText
                          : '';
                      return LineTooltipItem(
                        '${s.y.toStringAsFixed(2)} %',
                        const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                        children: t.isEmpty
                            ? null
                            : [
                                TextSpan(
                                  text: '\n$t',
                                  style: TextStyle(
                                    color: Colors.white
                                        .withValues(alpha: 0.7),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ],
                      );
                    }).toList(),
                  ),
                ),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: maxY / 4,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: tm.border,
                    strokeWidth: 0.6,
                    dashArray: const [3, 6],
                  ),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 38,
                      interval: maxY / 4,
                      getTitlesWidget: (v, _) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          v.toStringAsFixed(1),
                          style: TextStyle(
                            color: tm.textSub,
                            fontSize: 9,
                            fontFeatures:
                                const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    preventCurveOverShooting: true,
                    curveSmoothness: 0.2,
                    color: ThemeManager.green,
                    barWidth: 1.6,
                    isStrokeCapRound: true,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          ThemeManager.green.withValues(alpha: 0.22),
                          ThemeManager.green.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMaterial(ThemeManager tm) {
    return SizedBox(
      width: double.infinity,
      child: GlassCard(
        borderRadius: 18,
        accent: ThemeManager.cyan,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.science_outlined,
                  color: ThemeManager.cyan.withValues(alpha: 0.85),
                  size: 14),
              const SizedBox(width: 6),
              Text(
                'MATERIAL',
                style: TextStyle(
                  color: ThemeManager.cyan.withValues(alpha: 0.9),
                  fontSize: 9,
                  letterSpacing: 2.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _scanMaterial,
                child: Icon(Icons.qr_code_scanner,
                    color: ThemeManager.cyan.withValues(alpha: 0.7),
                    size: 16),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _materialCtrl,
            onChanged: (_) => _onMaterialChanged(),
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            minLines: 2,
            maxLines: null,
            style: TextStyle(
              color: tm.textPrimary,
              fontSize: 13,
              height: 1.5,
            ),
            decoration: InputDecoration(
              hintText: 'Scan a material QR or type here…',
              hintStyle: TextStyle(
                color: tm.textSub.withValues(alpha: 0.5),
                fontSize: 12,
              ),
              isCollapsed: true,
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 6, horizontal: 0),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
            cursorColor: ThemeManager.cyan,
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildNotes(ThemeManager tm) {
    return SizedBox(
      width: double.infinity,
      child: GlassCard(
        borderRadius: 18,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'NOTES',
                style: TextStyle(
                  color: tm.textSub,
                  fontSize: 9,
                  letterSpacing: 2.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Icon(Icons.edit_note,
                  color: tm.textSub.withValues(alpha: 0.6), size: 14),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _notesCtrl,
            onChanged: (_) => _onNotesChanged(),
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            minLines: 4,
            maxLines: null,
            style: TextStyle(
              color: tm.textPrimary,
              fontSize: 14,
              height: 1.5,
            ),
            decoration: InputDecoration(
              hintText: 'Tap to add notes…',
              hintStyle: TextStyle(
                color: tm.textSub.withValues(alpha: 0.5),
                fontSize: 13,
              ),
              isCollapsed: true,
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 6, horizontal: 0),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
            cursorColor: ThemeManager.cyan,
          ),
        ],
      ),
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  final String label, value, unit;
  final Color tone;
  final ThemeManager tm;
  const _SummaryStat({
    required this.label,
    required this.value,
    required this.unit,
    required this.tone,
    required this.tm,
  });
  @override
  Widget build(BuildContext context) {
    return GlassCard(
      borderRadius: 18,
      accent: tone,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: TextStyle(
                  color: tm.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w400,
                  height: 1.0,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 2),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    unit,
                    style: TextStyle(color: tm.textSub, fontSize: 9),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  "Save to device" — copy recordings into PUBLIC storage
//  (Documents/<app folder>/) so they survive an app uninstall.
//
//  Shared by the batch action bar and the single-recording page, so the
//  permission flow and the wording stay identical in both places.
// ══════════════════════════════════════════════════════════════════════════
Future<void> _saveFilesToDevice(BuildContext context, List<File> files) async {
  if (files.isEmpty) return;
  final tm = ThemeManager.instance;
  final messenger = ScaffoldMessenger.of(context);

  void snack(String msg, {Color? accent, SnackBarAction? action}) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: TextStyle(color: accent ?? tm.textPrimary)),
        backgroundColor: tm.surface,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: action == null ? 3 : 6),
        action: action,
      ));
  }

  final granted = await BackupStore.ensurePermission();
  if (!granted) {
    snack(
      'All-files access is required to save recordings to this device.',
      accent: ThemeManager.orange,
      action: SnackBarAction(
        label: 'SETTINGS',
        textColor: ThemeManager.cyan,
        onPressed: () {
          BackupStore.openSettings();
        },
      ),
    );
    return;
  }

  final n = await BackupStore.saveAll(files);
  if (n == 0) {
    snack('Could not save to device storage.', accent: ThemeManager.red);
  } else {
    snack('Saved $n file${n == 1 ? '' : 's'} to ${BackupStore.displayPath}',
        accent: ThemeManager.green);
  }
}
