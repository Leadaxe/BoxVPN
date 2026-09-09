import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../controllers/home_controller.dart';
import '../models/parser_config.dart' show SpeedTestServer;
import '../services/app_log.dart';
import '../services/error_format.dart';
import '../services/format_utils.dart' show formatTimeHm;
import '../services/l10n/template_aware_state.dart';
import '../services/template_loader.dart';
import '../services/l10n/locale_controller.dart';
import '../widgets/safe_bottom.dart';

class SpeedTestScreen extends StatefulWidget {
  const SpeedTestScreen({super.key, required this.homeController});

  final HomeController homeController;

  @override
  State<SpeedTestScreen> createState() => _SpeedTestScreenState();
}

class _SpeedTestResult {
  _SpeedTestResult({
    required this.timestamp,
    required this.ping,
    required this.download,
    required this.upload,
    required this.proxy,
    required this.vpnEnabled,
    required this.server,
  });

  final DateTime timestamp;
  final double ping;
  final double download;
  final double upload;
  final String proxy;
  final bool vpnEnabled;
  final String server;
}

/// Session-scoped history — survives screen close, cleared on app restart.
final _sessionHistory = <_SpeedTestResult>[];

class _SpeedTestScreenState extends State<SpeedTestScreen>
    with TemplateAwareState<SpeedTestScreen> {
  bool _running = false;

  /// §279 — пусто = idle-подсказка (speedStatusIdle); локализованные статусы
  /// пишутся в момент присвоения (эфемерные, не переживают смену локали).
  String _status = '';
  double _downloadMbps = 0;
  double _uploadMbps = 0;
  double _ping = 0;
  double _progress = 0;
  List<_SpeedTestResult> get _history => _sessionHistory;
  int _streams = 4;

  /// §279 — server selection is keyed by the stable template `id`, not by
  /// list index (order/names may change between template versions).
  String? _selectedServerId;

  // Loaded from wizard_template (§279 — typed SpeedTestOptionsModel).
  var _servers = <SpeedTestServer>[];
  var _streamOptions = <int>[1, 4, 10];

  /// Index of the selected server; unknown/absent id falls back to the
  /// default (first) server.
  int get _selectedServer {
    final i = _servers.indexWhere((s) => s.id == _selectedServerId);
    return i >= 0 ? i : 0;
  }

  String _serverId(int i) => _servers[i].id.isNotEmpty ? _servers[i].id : '$i';

  /// §279 — fetch через TemplateAwareState: первый вызов — полная загрузка,
  /// смена локали — refetch имён серверов (выбор/`_streams` юзера не трогаем).
  @override
  void onLocaleTemplateFetch({required bool first}) {
    unawaited(_loadConfig(seedDefaults: first));
  }

  Future<void> _loadConfig({required bool seedDefaults}) async {
    final template = await TemplateLoader.load();
    final opts = template.speedTestOptionsModel;

    if (mounted) {
      setState(() {
        if (opts.servers.isNotEmpty) _servers = opts.servers;
        if (opts.streamOptions.isNotEmpty) _streamOptions = opts.streamOptions;
        if (seedDefaults && opts.defaultStreams != null) {
          _streams = opts.defaultStreams!;
        }
      });
    }
  }

  String get _currentProxy {
    final state = widget.homeController.state;
    if (!state.tunnelUp) return 'Direct'; // l10n-exempt: outbound tag-like label
    return state.activeInGroup ?? state.selectedGroup ?? 'VPN';
  }

  bool get _vpnEnabled => widget.homeController.state.tunnelUp;

  Future<void> _runTest() async {
    if (_running) return;
    setState(() {
      _running = true;
      _status = getLocalText.s("Testing ping...");
      _downloadMbps = 0;
      _uploadMbps = 0;
      _ping = 0;
      _progress = 0;
    });

    try {
      // Ping — 5 attempts, trimmed mean
      final pingResult = await _testPing();
      if (!mounted) return;
      setState(() {
        _ping = pingResult;
        _progress = 0.15;
        _status = getLocalText.s("Testing download...");
      });

      // Download — 4 parallel streams
      final dlSpeed = await _testDownload();
      if (!mounted) return;
      setState(() {
        _downloadMbps = dlSpeed;
        _progress = 0.65;
        _status = getLocalText.s("Testing upload...");
      });

      // Upload
      final ulSpeed = await _testUpload();
      if (!mounted) return;
      setState(() {
        _uploadMbps = ulSpeed;
        _progress = 1.0;
        _status = getLocalText.s("Complete");
      });

      // Save to session history
      _history.insert(
        0,
        _SpeedTestResult(
          timestamp: DateTime.now(),
          ping: _ping,
          download: _downloadMbps,
          upload: _uploadMbps,
          proxy: _currentProxy,
          vpnEnabled: _vpnEnabled,
          server: _serverName(_selectedServer),
        ),
      );
      if (_history.length > 10) _history.removeLast();
    } catch (e) {
      if (mounted) {
        setState(() =>
            _status = getLocalText.s("Error: %s", formatUserError(e).render()));
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  String _serverPingUrl(int i) =>
      _servers[i].pingUrl.isNotEmpty ? _servers[i].pingUrl : _serverDownloadUrl(i);

  Future<double> _testPing() async {
    final url = _serverPingUrl(_selectedServer);
    final times = <int>[];
    for (var i = 0; i < 5; i++) {
      try {
        final sw = Stopwatch()..start();
        final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
        sw.stop();
        if (response.statusCode < 400) {
          times.add(sw.elapsedMilliseconds);
        }
      } catch (e) {
        AppLog.I.debug('[speedtest] ping attempt $i failed: $e');
      }
    }

    if (times.isEmpty) return -1;
    times.sort();
    // Trimmed mean: drop min and max if we have 3+
    if (times.length >= 3) {
      final trimmed = times.sublist(1, times.length - 1);
      return trimmed.reduce((a, b) => a + b) / trimmed.length;
    }
    return times.reduce((a, b) => a + b) / times.length;
  }

  String _serverName(int i) =>
      _servers[i].name.isNotEmpty ? _servers[i].name : getLocalText.s("Server %d", i);
  String _serverDownloadUrl(int i) => _servers[i].downloadUrl;
  String? _serverUploadUrl(int i) => _servers[i].uploadUrl;
  String _serverUploadMethod(int i) => _servers[i].uploadMethod;

  /// Download test: parallel streams with real-time speed updates.
  Future<double> _testDownload() async {
    final url = _serverDownloadUrl(_selectedServer);
    if (url.isNotEmpty) {
      try {
        final result = await _multiStreamDownload(url, _streams);
        if (result > 0) return result;
      } catch (e) {
        AppLog.I.debug('[speedtest] download (primary) failed: $e');
      }
    }
    // Fallback to other servers
    for (var i = 0; i < _servers.length; i++) {
      if (i == _selectedServer) continue;
      final fallbackUrl = _serverDownloadUrl(i);
      if (fallbackUrl.isEmpty) continue;
      try {
        final result = await _multiStreamDownload(fallbackUrl, _streams);
        if (result > 0) return result;
      } catch (e) {
        AppLog.I.debug('[speedtest] download (fallback server $i) failed: $e');
      }
    }
    return 0;
  }

  var _dlBytesTotal = 0;

  Future<double> _multiStreamDownload(String url, int streams) async {
    final client = http.Client();
    _dlBytesTotal = 0;
    final sw = Stopwatch()..start();

    // Real-time UI update timer
    final uiTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || !_running) return;
      final seconds = sw.elapsedMilliseconds / 1000.0;
      if (seconds > 0.5) {
        setState(() {
          _downloadMbps = (_dlBytesTotal * 8 / 1000000) / seconds;
        });
      }
    });

    try {
      final futures = <Future<void>>[];
      for (var i = 0; i < streams; i++) {
        futures.add(_downloadStream(client, url));
      }
      await Future.wait(futures).timeout(const Duration(seconds: 15));
      sw.stop();
      uiTimer.cancel();

      if (_dlBytesTotal == 0) return 0;
      final seconds = sw.elapsedMilliseconds / 1000.0;
      return (_dlBytesTotal * 8 / 1000000) / seconds;
    } catch (_) {
      sw.stop();
      uiTimer.cancel();
      if (_dlBytesTotal == 0) return 0;
      final seconds = sw.elapsedMilliseconds / 1000.0;
      return (_dlBytesTotal * 8 / 1000000) / seconds;
    } finally {
      client.close();
    }
  }

  Future<void> _downloadStream(http.Client client, String url) async {
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request).timeout(const Duration(seconds: 15));
      await for (final chunk in response.stream) {
        _dlBytesTotal += chunk.length;
      }
    } catch (e) {
      AppLog.I.debug('[speedtest] download stream aborted: $e');
    }
  }

  Future<double> _testUpload() async {
    // 2 parallel upload streams, 2MB each
    final client = http.Client();
    try {
      final data = Uint8List(5 * 1024 * 1024);
      var totalBytes = 0;
      final sw = Stopwatch()..start();

      final futures = <Future<int>>[];
      for (var i = 0; i < 2; i++) {
        futures.add(_uploadStream(client, data));
      }

      final results = await Future.wait(futures).timeout(const Duration(seconds: 30));
      sw.stop();

      for (final bytes in results) {
        totalBytes += bytes;
      }

      if (totalBytes == 0) return 0;
      final seconds = sw.elapsedMilliseconds / 1000.0;
      return (totalBytes * 8 / 1000000) / seconds;
    } finally {
      client.close();
    }
  }

  Future<int> _uploadStream(http.Client client, Uint8List data) async {
    try {
      final uploadUrl = _serverUploadUrl(_selectedServer) ?? _serverDownloadUrl(_selectedServer);
      final uri = Uri.parse(uploadUrl);
      final headers = {'Content-Type': 'application/octet-stream'};
      final method = _serverUploadMethod(_selectedServer);
      if (method == 'POST') {
        await http.post(uri, body: data, headers: headers).timeout(const Duration(seconds: 30));
      } else {
        await http.put(uri, body: data, headers: headers).timeout(const Duration(seconds: 30));
      }
      return data.length;
    } catch (_) {
      return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(getLocalText.s("Speed Test"))),
      body: ListView(
        padding: const EdgeInsets.all(24).withSafeBottom(context),
        children: [
          // Proxy indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  _vpnEnabled ? Icons.vpn_key : Icons.public,
                  size: 16,
                  color: _vpnEnabled ? cs.primary : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  _vpnEnabled
                      ? getLocalText.s("Via: %s", _currentProxy)
                      : getLocalText.s("Direct (no VPN)"),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Ping
          _buildGauge(
            getLocalText.s("Ping"),
            _ping < 0
                ? getLocalText.s("Failed")
                : '${_ping.toStringAsFixed(0)} ms',
            Icons.network_ping,
            cs.primary,
          ),
          const SizedBox(height: 24),

          // Download
          _buildGauge(
            getLocalText.s("Download"),
            '${_downloadMbps.toStringAsFixed(1)} Mbps',
            Icons.arrow_downward,
            cs.tertiary,
          ),
          const SizedBox(height: 24),

          // Upload
          _buildGauge(
            getLocalText.s("Upload"),
            '${_uploadMbps.toStringAsFixed(1)} Mbps',
            Icons.arrow_upward,
            cs.secondary,
          ),
          const SizedBox(height: 32),

          if (_running) LinearProgressIndicator(value: _progress),
          const SizedBox(height: 8),
          Text(_status.isEmpty ? getLocalText.s("Tap Start to begin") : _status,
              style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
          const SizedBox(height: 24),

          // Settings
          if (!_running) ...[
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue:
                        _servers.isEmpty ? null : _serverId(_selectedServer),
                    decoration: InputDecoration(
                      labelText: getLocalText.s("Server"),
                      isDense: true,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                    style: TextStyle(fontSize: 13, color: cs.onSurface),
                    items: List.generate(_servers.length, (i) =>
                      DropdownMenuItem(value: _serverId(i), child: Text(_serverName(i))),
                    ),
                    onChanged: (v) { if (v != null) setState(() => _selectedServerId = v); },
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 100,
                  child: DropdownButtonFormField<int>(
                    initialValue: _streams,
                    decoration: InputDecoration(
                      labelText: getLocalText.s("Streams"),
                      isDense: true,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                    style: TextStyle(fontSize: 13, color: cs.onSurface),
                    items: _streamOptions.map((n) =>
                      DropdownMenuItem(value: n, child: Text('$n')),
                    ).toList(),
                    onChanged: (v) { if (v != null) setState(() => _streams = v); },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],

          // Start button
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _running ? null : _runTest,
              icon: Icon(_running ? Icons.hourglass_top : Icons.speed),
              label: Text(_running
                  ? getLocalText.s("Testing...")
                  : getLocalText.s("Start Test")),
            ),
          ),

          // History
          if (_history.isNotEmpty) ...[
            const SizedBox(height: 32),
            Text(getLocalText.s("Session History"), style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            ..._history.map((r) => _buildHistoryTile(r, theme, cs)),
          ],
        ],
      ),
    );
  }

  Widget _buildGauge(String label, String value, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, size: 32, color: color),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ],
    );
  }

  Widget _buildHistoryTile(_SpeedTestResult r, ThemeData theme, ColorScheme cs) {
    final time = formatTimeHm(r.timestamp);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(time, style: theme.textTheme.bodySmall),
          ),
          Icon(
            r.vpnEnabled ? Icons.vpn_key : Icons.public,
            size: 12,
            color: cs.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.proxy,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  r.server,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 10,
                    color: cs.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Text(
            // l10n-exempt: latency value + unit suffix
            '${r.ping.toStringAsFixed(0)}ms',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.primary),
          ),
          const SizedBox(width: 12),
          Text(
            '↓${r.download.toStringAsFixed(1)}',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.tertiary),
          ),
          const SizedBox(width: 8),
          Text(
            '↑${r.upload.toStringAsFixed(1)}',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.secondary),
          ),
        ],
      ),
    );
  }
}
