import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/format_utils.dart';
import '../services/l10n/locale_controller.dart';
import '../services/oom_reports.dart';
import '../services/oom_share.dart';
import '../services/ui_helpers.dart';
import '../widgets/big_text_view.dart';
import '../widgets/safe_bottom.dart';

/// §318 — вкладка «OOM» на экране Debug: снимки памяти, снятые ядром.
///
/// Пишет их oom-killer ядра (§271) при превышении порога RSS: pprof-профили
/// кучи в момент реальной проблемы, на устройстве пользователя, без участия
/// разработчика. До §318 они лежали в `files/oom_reports/` недостижимыми —
/// и без ротации доросли на тест-устройстве до 427 МБ.
///
/// Отдельная вкладка, а не строки в «Crashes»: краш и OOM — разные события
/// (паника против давления памяти), в общем списке сигнал теряется.
class OomReportsTab extends StatefulWidget {
  const OomReportsTab({super.key});

  @override
  State<OomReportsTab> createState() => _OomReportsTabState();
}

class _OomReportsTabState extends State<OomReportsTab>
    with SnackHelper, AutomaticKeepAliveClientMixin {
  List<OomReportFile>? _reports;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await OomReports.list();
    if (!mounted) return;
    setState(() => _reports = list);
  }

  Future<void> _share(OomReportFile r) async {
    final ok = await shareOomReport(r);
    if (!mounted || ok) return;
    showSnack(getLocalText.s("Share failed: %s", r.name));
  }

  /// Удаление всех снимков — операция необратимая и по объёму заметная,
  /// поэтому через тот же confirm, что и остальные удаления (§219).
  Future<void> _clearAll(int total) async {
    final ok = await showDeleteConfirmDialog(
      context,
      title: getLocalText.s("Delete all OOM reports?"),
      message: getLocalText.s(
          "This frees %s. Memory profiles cannot be recovered afterwards.",
          formatBytes(total)),
      confirmLabel: getLocalText.s("Delete all"),
    );
    if (ok != true) return;
    final removed = await OomReports.clear();
    if (!mounted) return;
    showSnack(getLocalText.plural("%d OOM reports deleted", removed));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final reports = _reports;
    if (reports == null) {
      return const Center(child: CircularProgressIndicator());
    }
    var total = 0;
    for (final r in reports) {
      total += r.size;
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  reports.isEmpty
                      ? getLocalText.s("Memory snapshots taken by the core when it approached its memory limit.")
                      // Суммарный размер в заголовке — главное, что нужно
                      // знать про эту папку: она растёт сама.
                      : getLocalText.plural(
                          "%1\$d snapshots · %2\$s. Tap to inspect, share to get the pprof profiles.",
                          reports.length,
                          formatBytes(total)),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: getLocalText.s("Refresh"),
                onPressed: _load,
              ),
              IconButton(
                icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                tooltip: getLocalText.s("Delete all OOM reports"),
                onPressed: reports.isEmpty ? null : () => _clearAll(total),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: reports.isEmpty
              ? _buildEmpty(context)
              : _buildList(context, reports),
        ),
      ],
    );
  }

  /// Пустой список — нормальное состояние, а не поломка экрана: ядро просто
  /// не упиралось в лимит памяти.
  Widget _buildEmpty(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.memory_outlined,
                  size: 40, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              Text(
                getLocalText.s("No OOM reports"),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                getLocalText.s("The core has not hit its memory limit. Snapshots appear here only when the OOM killer fires."),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );

  Widget _buildList(BuildContext context, List<OomReportFile> reports) {
    return ListView.separated(
      itemCount: reports.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final r = reports[i];
        return ListTile(
          leading: Icon(
            Icons.memory,
            color: Theme.of(context).colorScheme.tertiary,
          ),
          title: Text(formatDateTime(r.mtime)),
          subtitle: Text(
            _subtitleOf(r),
            style: const TextStyle(fontSize: 12),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.ios_share, size: 20),
            tooltip: getLocalText.s("Share the OOM report"),
            onPressed: () => _share(r),
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => OomReportViewScreen(report: r),
            ),
          ),
        );
      },
    );
  }

  /// Размер каталога + RSS на момент снимка + версия ядра. RSS в подписи —
  /// чтобы отличить «подобрался к лимиту» от «взлетел» не открывая снимок.
  String _subtitleOf(OomReportFile r) {
    final parts = <String>[formatBytes(r.size)];
    if (r.memoryUsage != null) parts.add(r.memoryUsage!);
    if (r.coreVersion != null) parts.add(r.coreVersion!);
    return parts.join(' · ');
  }
}

/// §318 — просмотр одного снимка: таблица memstats из `metadata.json`, ниже
/// `go.log` ядра на момент срабатывания killer'а.
///
/// pprof-профили тут не показываем — их читает `go tool pprof`, для этого
/// есть share. Экран отвечает на вопрос «сколько и чего было занято», а не
/// заменяет профайлер.
class OomReportViewScreen extends StatefulWidget {
  const OomReportViewScreen({super.key, required this.report});

  final OomReportFile report;

  @override
  State<OomReportViewScreen> createState() => _OomReportViewScreenState();
}

class _OomReportViewScreenState extends State<OomReportViewScreen>
    with SnackHelper {
  Map<String, Object?>? _meta;
  String? _log;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    Map<String, Object?>? meta;
    try {
      final j = jsonDecode(await File(widget.report.path).readAsString());
      if (j is Map) meta = j.cast<String, Object?>();
    } catch (_) {
      // Битые метаданные — покажем хотя бы лог.
    }
    String? log;
    try {
      final f = File('${widget.report.dirPath}/$kOomLogName');
      if (await f.exists()) log = await f.readAsString();
    } catch (_) {
      // Лога может не быть: ядро пишет его только при непустом буфере.
    }
    if (!mounted) return;
    setState(() {
      _meta = meta;
      _log = log;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    return Scaffold(
      appBar: AppBar(
        title: Text(formatDateTime(r.mtime)),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: getLocalText.s("Share the OOM report"),
            onPressed: () async {
              final ok = await shareOomReport(r);
              if (!mounted || ok) return;
              showSnack(getLocalText.s("Share failed: %s", r.name));
            },
          ),
        ],
      ),
      // §333 — снапшот core-log читается целиком; в едином SelectableText
      // это Paragraph на весь лог. Мета — шапкой, лог — построчными sliver'ами.
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(12),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildMeta(context),
                        if (_log != null) ...[
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Text(
                                getLocalText.s("Core log at snapshot time"),
                                style:
                                    Theme.of(context).textTheme.titleSmall,
                              ),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.copy, size: 16),
                                tooltip: getLocalText.s("Copy"),
                                visualDensity: VisualDensity.compact,
                                onPressed: () async {
                                  await Clipboard.setData(
                                      ClipboardData(text: _log!));
                                  if (!mounted) return;
                                  showSnack(getLocalText
                                      .s("Copied to clipboard"));
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                        ],
                      ],
                    ),
                  ),
                ),
                if (_log != null)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12).withSafeBottom(context),
                    sliver: BigTextSliver(
                      text: _log!,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        height: 1.3,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  /// Порядок строк — от «сколько всего» к деталям кучи и GC: читающий сверху
  /// вниз сначала видит масштаб, потом причину. Ключи, которых нет в снимке,
  /// пропускаем молча — набор полей у разных версий ядра отличается.
  ///
  /// Подписи — литеральные `getLocalText.s("…")`, а НЕ `s(label)` по таблице
  /// «поле → строка»: чекер `tool/l10n/ui_check.dart` видит только литералы,
  /// и при динамическом ключе восемнадцать подписей молча остались бы без
  /// перевода (§l10n — английский текст и есть ключ словаря).
  static List<(String, String)> _metaRows() => [
        ('memoryUsage', getLocalText.s("Process memory (RSS)")),
        ('availableMemory', getLocalText.s("Available memory")),
        ('sys', getLocalText.s("Reserved from OS")),
        ('heapInuse', getLocalText.s("Heap in use")),
        ('heapAlloc', getLocalText.s("Heap allocated")),
        ('heapIdle', getLocalText.s("Heap idle")),
        ('heapReleased', getLocalText.s("Heap released")),
        ('heapSys', getLocalText.s("Heap from OS")),
        ('heapObjects', getLocalText.s("Heap objects")),
        ('stackInuse', getLocalText.s("Stack in use")),
        ('numGoroutine', getLocalText.s("Goroutines")),
        ('numGC', getLocalText.s("GC cycles")),
        ('nextGC', getLocalText.s("Next GC at")),
        ('lastGC', getLocalText.s("Last GC")),
        ('totalAlloc', getLocalText.s("Allocated in total")),
        ('coreVersion', getLocalText.s("Core version")),
        ('goVersion', getLocalText.s("Go version")),
        ('recordedAt', getLocalText.s("Recorded at")),
      ];

  Widget _buildMeta(BuildContext context) {
    final meta = _meta;
    if (meta == null || meta.isEmpty) {
      return Text(
        getLocalText.s("Metadata is missing or unreadable."),
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    final rows = <TableRow>[];
    for (final (key, label) in _metaRows()) {
      final value = meta[key];
      if (value == null) continue;
      rows.add(TableRow(children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(label,
              style: Theme.of(context).textTheme.bodySmall),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: SelectableText(
            '$value',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ]));
    }
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(1.2),
        1: FlexColumnWidth(1),
      },
      children: rows,
    );
  }
}
