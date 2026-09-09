// §048 / §160 — Live system-wide tab.
//
// 4-й tab в `StatsScreen`. Показывает все TrafficEvent'ы со всех apps в
// real-time, без выбора target. Решает discovery-кейс: «не знаю какой app
// виноват, что вообще происходит на устройстве». Использует тот же
// `_globalRollingBuffer` что Per-app session backfill.
//
// §160 — тело (тогл Live/Aggregated + общий фильтр + детали + пауза)
// делегировано общему [TraceExplorer] (тот же движок, что в per-app trace,
// без дубля кода). Здесь остаётся только специфика system-wide:
//   - SSE-подписка на globalLiveStream → локальный snapshot `_events`;
//   - recording START/STOP (globalRecording);
//   - app multi-select pre-фильтр (по package, auto-collected из feed'а) —
//     уникален для system-wide (в per-app trace процесс один);
//   - unattributed banner.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../services/traffic_profiler.dart';
import '../widgets/core_logs_hint_banner.dart';
import 'live_events_tab/dns_health_banner.dart';
import 'live_events_tab/recording_header.dart';
import 'live_events_tab/unattributed_banner.dart';
import 'per_app_trace_tab/session_json.dart';
import 'stats_screen/profiler_filter.dart';
import 'stats_screen/profiler_filters.dart';
import 'stats_screen/trace_explorer.dart';
import '../services/l10n/locale_controller.dart';
import '../widgets/app_bottom_sheet.dart';

class LiveEventsTab extends StatefulWidget {
  const LiveEventsTab({super.key, this.subController, this.homeController});

  // §262 — прокидываются в DNS-health баннер для навигационных кнопок листа
  // (Open DNS settings / Enable FakeIP). null → лист чисто информационный.
  final SubscriptionController? subController;
  final HomeController? homeController;

  @override
  State<LiveEventsTab> createState() => _LiveEventsTabState();
}

class _LiveEventsTabState extends State<LiveEventsTab> {
  StreamSubscription<Map<String, Object?>>? _sub;
  // Локальный snapshot — приходит из global rolling buffer'а на init,
  // потом обновляется через SSE feed. Live-снимок == _events newest-last.
  final List<TrafficEvent> _events = [];
  Timer? _ticker; // для refresh «Recording 02:34» каждую секунду

  // §170 — троттл тяжёлой пересборки списка из global buffer (clear+addAll до
  // 3000 + _trackApp в цикле + setState). SSE-события на FAST-стриме идут
  // десятками/сек → без троттла сотни полных ребилдов/сек = фриз и краш
  // (watchdog/память). Окно мерим от КОНЦА отработанной пересборки, не от
  // старта: иначе на медленном пересчёте следующий тик наслаивался бы. Буфер
  // копится в профайлере и без UI-пересборки — события не теряются, отстаёт
  // только отрисовка (≤700мс). Тот же приём что в stats_screen (§166/§170).
  static const _rebuildThrottle = Duration(milliseconds: 700);
  DateTime? _rebuiltAt;
  bool _pendingRebuild = false;
  Timer? _rebuildTimer;

  // §044/new-profiler — фильтр (app-ось + типы + поиск) теперь в общей модели,
  // редактируется фильтр-окном (ProfilerFilterSheet). Старый локальный
  // _appFilter/_seenApps удалён — app-выбор живёт в _filter.apps.
  // §244 — фильтр session-scope (ProfilerFilters.liveTab), не поле State:
  // переживает переключение вкладок и уход со Stats-экрана. НЕ dispose'ить.
  ProfilerFilter get _filter => ProfilerFilters.liveTab;

  @override
  void initState() {
    super.initState();
    // §048 — recording state управляется explicit через
    // [TrafficProfiler.I.startGlobalRecording] (юзер тапает ▶ START в хедере).
    // Запись persistent (продолжается при уходе с вкладки) — прежнее поведение.
    final snapshot = TrafficProfiler.I.globalSnapshot(seconds: 60);
    _events.addAll(snapshot);
    _sub = TrafficProfiler.I.globalLiveStream().listen(_onEvent);
    TrafficProfiler.I.addListener(_onProfilerChanged);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && TrafficProfiler.I.isGlobalRecording) setState(() {});
    });
  }

  void _onProfilerChanged() {
    if (!mounted) return;
    setState(() {
      // STOP — буфер заморожен, _events остаётся; START — clear.
      if (!TrafficProfiler.I.isGlobalRecording) return;
      _events.clear();
    });
  }

  void _toggleRecording() {
    if (TrafficProfiler.I.isGlobalRecording) {
      TrafficProfiler.I.stopGlobalRecording();
    } else {
      TrafficProfiler.I.startGlobalRecording();
    }
  }

  /// §044 — экспорт записанных событий (весь буфер). Share / Copy JSON.
  Future<void> _exportEvents() async {
    if (_events.isEmpty) return;
    final json =
        const JsonEncoder.withIndent('  ').convert(eventsToJson(_events));
    if (!mounted) return;
    await showAppBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.share),
              title: Text(getLocalText.plural("Share %d events (JSON)", _events.length)),
              onTap: () {
                Navigator.pop(sheetCtx);
                Share.share(json, subject: 'LxBox profiler export');
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(getLocalText.s("Copy JSON to clipboard")),
              onTap: () async {
                Navigator.pop(sheetCtx);
                await Clipboard.setData(ClipboardData(text: json));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(getLocalText.s("Export JSON copied"))),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _onEvent(Map<String, Object?> msg) {
    if (msg['event'] != 'traffic_event') return;
    final data = msg['data'];
    if (data is! Map) return;
    // §170 — троттл: пересборка не чаще _rebuildThrottle, окно от КОНЦА прошлой
    // (метка ставится после _rebuildFromBuffer), не от старта. На FAST-стриме
    // события идут десятками/сек; пересборка списка (clear+addAll ≤3000 +
    // _trackApp + setState) на каждое = захлёбывание. Буфер копится в профайлере
    // и без UI-пересборки — событие не теряется, отстаёт ≤_rebuildThrottle.
    final now = DateTime.now();
    if (_rebuiltAt != null &&
        now.difference(_rebuiltAt!) < _rebuildThrottle) {
      // В окне — отложим один trailing-ребилд, чтобы последнее событие дошло.
      if (!_pendingRebuild) {
        _pendingRebuild = true;
        final wait = _rebuildThrottle - now.difference(_rebuiltAt!);
        _rebuildTimer = Timer(wait, () {
          _pendingRebuild = false;
          if (mounted) _rebuildFromBuffer();
        });
      }
      return;
    }
    _rebuildFromBuffer();
  }

  /// Пересобрать локальный снимок из global rolling buffer'а профайлера.
  /// Метка _rebuiltAt ставится В КОНЦЕ — окно троттла отсчитывается от
  /// завершения работы, не от старта.
  void _rebuildFromBuffer() {
    if (!mounted) return;
    setState(() {
      final fresh = TrafficProfiler.I.globalRollingBuffer;
      _events
        ..clear()
        ..addAll(fresh);
    });
    _rebuiltAt = DateTime.now();
  }

  @override
  void dispose() {
    _sub?.cancel();
    TrafficProfiler.I.removeListener(_onProfilerChanged);
    // §244 — _filter НЕ диспоузим: session-объект (ProfilerFilters.liveTab).
    _ticker?.cancel();
    _rebuildTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        LiveRecordingHeader(
          eventCount: _events.length,
          onToggle: _toggleRecording,
          // §044 — экспорт справа от большой кнопки (в строке дубль убран).
          onExport: _exportEvents,
        ),
        const Divider(height: 1),
        const CoreLogsHintBanner(),
        if (TrafficProfiler.I.unattributedBannerActive)
          const UnattributedBanner(),
        // §262 — деградация DNS при живой связи: тап открывает лист-подсказку.
        if (TrafficProfiler.I.dnsHealthUnhealthy)
          DnsHealthBanner(
            subController: widget.subController,
            homeController: widget.homeController,
          ),
        Expanded(
          child: TraceExplorer(
            // System-wide: unattributed события уже внутри globalRollingBuffer
            // как обычные строки (с confidence=unattributed). Отдельной
            // «no owner» секции (как в per-app) тут нет → unattributed=[].
            // App-ось фильтра применяется внутри TraceExplorer через _filter.
            // §044 — record-управление НЕ передаём: запись через большую кнопку
            // в хедере (дубль из control-строки убран). showRecording=true
            // оставляет аггрегацию/фильтр/паузу, но без кнопки записи и export.
            events: _events,
            unattributed: const [],
            recording: TrafficProfiler.I.isGlobalRecording,
            filter: _filter,
            // Profiler-вкладка: retention-кнопка нужна, record-кнопка — нет.
            showRetention: true,
          ),
        ),
      ],
    );
  }
}
