import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/l10n/locale_controller.dart';
import '../services/warp/scan/scan_pool.dart';
import '../services/warp/warp_endpoint_picker.dart';
import '../services/usage_region.dart';

/// §305 — экран настройки WARP-эксперимента (генератор нод). Вынесен из попапа:
/// JSON-пул большой, в диалоге тесно. Пользователь задаёт число нод и
/// редактирует JSON пула (по умолчанию bundled asset), генератор рандомит по
/// нему. Возвращает `(count, pool)` через `Navigator.pop` или null (отмена).
class WarpExperimentScreen extends StatefulWidget {
  const WarpExperimentScreen({super.key});

  @override
  State<WarpExperimentScreen> createState() => _WarpExperimentScreenState();
}

class _WarpExperimentScreenState extends State<WarpExperimentScreen> {
  final _countCtl = TextEditingController(text: '20');
  final _jsonCtl = TextEditingController();
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Дефолт JSON — сырой asset (наш пул). Юзер правит под свои диапазоны.
    WarpEndpointPicker.loadRawJson().then((raw) {
      if (!mounted) return;
      setState(() {
        _jsonCtl.text = raw;
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _countCtl.dispose();
    _jsonCtl.dispose();
    super.dispose();
  }

  /// §305 — JSON пула → [ScanPool]. null если битый JSON/структура.
  /// §425 — секция `loc.<регион>` из этого же JSON накладывается по той же
  /// настройке, что и в визарде: юзер правит один формат.
  Future<ScanPool?> _parsePool(String raw) async {
    try {
      final region = await UsageRegion.effective();
      return ScanPool.fromFullJson(jsonDecode(raw) as Map<String, dynamic>,
          region: region);
    } catch (_) {
      return null;
    }
  }

  Future<void> _resetJson() async {
    final raw = await WarpEndpointPicker.loadRawJson();
    if (mounted) setState(() => _jsonCtl.text = raw);
  }

  Future<void> _create() async {
    final pool = await _parsePool(_jsonCtl.text);
    if (!mounted) return;
    if (pool == null) {
      setState(() => _error =
          getLocalText.s("Invalid pool JSON — check the structure."));
      return;
    }
    final count = (int.tryParse(_countCtl.text.trim()) ?? 20).clamp(1, 200);
    Navigator.of(context).pop((count: count, pool: pool));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(getLocalText.s("Make experiment")),
        actions: [
          TextButton(
            onPressed: _resetJson,
            child: Text(getLocalText.s("Reset")),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        getLocalText.s(
                            "Generates random WARP nodes (WireGuard/AWG/MASQUE h2/h3) into the «WARP GENERATOR» folder. Test them there and keep what works."),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _countCtl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly
                        ],
                        decoration: InputDecoration(
                          labelText: getLocalText.s("Number of nodes"),
                          helperText: getLocalText.s("1–200"),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        getLocalText.s(
                            "Endpoint pool (JSON) — IP blocks, ports and SNI the generator draws from. Edit to test your own ranges."),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _jsonCtl,
                        maxLines: null,
                        minLines: 18,
                        keyboardType: TextInputType.multiline,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12),
                        onChanged: (_) {
                          if (_error != null) setState(() => _error = null);
                        },
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          errorText: _error,
                          alignLabelWithHint: true,
                        ),
                      ),
                    ],
                  ),
                ),
                SafeArea(
                  minimum: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(getLocalText.s("Cancel")),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: _create,
                          child: Text(getLocalText.s("Create")),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
