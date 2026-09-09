import 'package:flutter/material.dart';

import '../../models/custom_rule.dart';
import '../../widgets/outbound_picker.dart';
import 'edit_controller.dart';
import '../../services/l10n/locale_controller.dart';
import '../../widgets/app_bottom_sheet.dart';

/// §247 — модальное окно «Action & Resolve» (за ⚙ рядом с Action-пикером).
///
/// Три режима одного правила:
/// - Route to outbound (дефолт) — терминальный route, как раньше;
/// - Route + Resolve first (флагман) — нетерминальный resolve ПЕРЕД route
///   (билдер эмитит два правила с одним матчем);
/// - Resolve only (advanced) — только resolve; трафик проваливается к
///   следующим правилам / Final (оранжевое предупреждение, осознанный выбор).
///
/// Единая панель Resolve options внизу — видна когда resolve активен в любом
/// из режимов. Advanced-поля (cache/ttl/timeout/subnet) — в раскрывашке.
Future<void> showActionResolveSheet(
  BuildContext context, {
  required CustomRuleEditController controller,
  required List<OutboundOption> outboundOptions,
}) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _ActionResolveSheet(
      controller: controller,
      outboundOptions: outboundOptions,
    ),
  );
}

class _ActionResolveSheet extends StatefulWidget {
  const _ActionResolveSheet({
    required this.controller,
    required this.outboundOptions,
  });

  final CustomRuleEditController controller;
  final List<OutboundOption> outboundOptions;

  @override
  State<_ActionResolveSheet> createState() => _ActionResolveSheetState();
}

class _ActionResolveSheetState extends State<_ActionResolveSheet> {
  // Локальное состояние — коммит в controller только по Done.
  late bool _resolveOnly;
  late bool _resolveFirst;
  late String _outbound;
  late String _strategy;
  late String _serverTag;
  late bool _disableCache;
  late bool _disableOptimisticCache;
  late final TextEditingController _ttlCtrl;
  late final TextEditingController _timeoutCtrl;
  late final TextEditingController _subnetCtrl;

  static const _strategies = [
    '', // inherit dns.strategy
    'prefer_ipv4',
    'prefer_ipv6',
    'ipv4_only',
    'ipv6_only',
  ];

  @override
  void initState() {
    super.initState();
    final r = widget.controller.resolve;
    _resolveOnly = r?.only ?? false;
    _resolveFirst = r != null && !r.only;
    _outbound = widget.controller.outbound;
    _strategy = r?.strategy ?? '';
    _serverTag = r?.serverTag ?? '';
    _disableCache = r?.disableCache ?? false;
    _disableOptimisticCache = r?.disableOptimisticCache ?? false;
    _ttlCtrl = TextEditingController(text: r?.rewriteTtl?.toString() ?? '');
    _timeoutCtrl = TextEditingController(text: r?.timeout ?? '');
    _subnetCtrl = TextEditingController(text: r?.clientSubnet ?? '');
  }

  @override
  void dispose() {
    _ttlCtrl.dispose();
    _timeoutCtrl.dispose();
    _subnetCtrl.dispose();
    super.dispose();
  }

  bool get _resolveActive => _resolveOnly || _resolveFirst;

  // ─── Advanced-поля: советующая валидация (битое = Done заблокирован) ──

  String? get _ttlError {
    final t = _ttlCtrl.text.trim();
    if (t.isEmpty) return null;
    final v = int.tryParse(t);
    if (v == null || v < 0) return 'Non-negative integer';
    return null;
  }

  String? get _timeoutError {
    final t = _timeoutCtrl.text.trim();
    if (t.isEmpty) return null;
    if (!RegExp(r'^\d+(ms|s|m|h)$').hasMatch(t)) return 'e.g. 5s, 500ms';
    return null;
  }

  static final _subnetPattern = RegExp(
      r'^([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9A-Fa-f:]+:[0-9A-Fa-f:]*)(/\d{1,3})?$');

  String? get _subnetError {
    final t = _subnetCtrl.text.trim();
    if (t.isEmpty) return null;
    if (!_subnetPattern.hasMatch(t)) return 'IP or CIDR, e.g. 1.2.3.0/24';
    return null;
  }

  bool get _hasErrors =>
      _resolveActive &&
      (_ttlError != null || _timeoutError != null || _subnetError != null);

  RuleResolve _collectResolve({required bool only}) => RuleResolve(
        only: only,
        strategy: _strategy,
        serverTag: _serverTag,
        disableCache: _disableCache,
        disableOptimisticCache: _disableOptimisticCache,
        rewriteTtl: int.tryParse(_ttlCtrl.text.trim()),
        timeout: _timeoutCtrl.text.trim(),
        clientSubnet: _subnetCtrl.text.trim(),
      );

  void _done() {
    final c = widget.controller;
    if (_resolveOnly) {
      c.setResolve(_collectResolve(only: true));
      // outbound в модели сохраняется (переключение назад не теряет выбор).
    } else if (_resolveFirst) {
      c.setResolve(_collectResolve(only: false));
      c.setOutbound(_outbound);
    } else {
      c.setResolve(null);
      c.setOutbound(_outbound);
    }
    Navigator.pop(context);
  }

  // ─── Preview: те же 1-2 записи, что эмитит билдер ─────────────────────

  String _previewText() {
    final name = widget.controller.nameCtrl.text.trim();
    final tag = name.isEmpty ? 'unnamed' : name;
    final resolve = StringBuffer('{"rule_set": "$tag", "action": "resolve"');
    if (_strategy.isNotEmpty) resolve.write(', "strategy": "$_strategy"');
    if (_serverTag.isNotEmpty) resolve.write(', "server": "$_serverTag"');
    if (_disableCache) resolve.write(', "disable_cache": true');
    if (_disableOptimisticCache) {
      resolve.write(', "disable_optimistic_cache": true');
    }
    final ttl = int.tryParse(_ttlCtrl.text.trim());
    if (ttl != null) resolve.write(', "rewrite_ttl": $ttl');
    if (_timeoutCtrl.text.trim().isNotEmpty) {
      resolve.write(', "timeout": "${_timeoutCtrl.text.trim()}"');
    }
    if (_subnetCtrl.text.trim().isNotEmpty) {
      resolve.write(', "client_subnet": "${_subnetCtrl.text.trim()}"');
    }
    resolve.write('}');
    final route = _outbound == kOutboundReject
        ? '{"rule_set": "$tag", "action": "reject"}'
        : '{"rule_set": "$tag", "outbound": "$_outbound"}';
    if (_resolveOnly) return '[$resolve]';
    if (_resolveFirst) return '[$resolve,\n $route]';
    return '[$route]';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scrollCtrl) => ListView(
        controller: scrollCtrl,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(getLocalText.s("Action & Resolve"),
              style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            getLocalText.s("How this rule directs and resolves matched traffic."),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),

          // ─── Режим: Route to outbound ────────────────────────────────
          RadioGroup<bool>(
            groupValue: _resolveOnly,
            onChanged: (v) => setState(() => _resolveOnly = v ?? false),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RadioListTile<bool>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: false,
                  title: Text(getLocalText.s("Route to outbound")),
                  subtitle: Text(getLocalText.s("Send matched traffic to a direction.")),
                ),
                if (!_resolveOnly)
                  Padding(
                    padding: const EdgeInsets.only(left: 44),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        OutboundPicker(
                          value: _outbound,
                          options: widget.outboundOptions,
                          onChanged: (v) => setState(() => _outbound = v),
                          dense: true,
                          label: 'Outbound',
                        ),
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _resolveFirst,
                          onChanged: (v) =>
                              setState(() => _resolveFirst = v ?? false),
                          title: Text(getLocalText.s("Resolve first")),
                          subtitle: Text(getLocalText.s("Resolve the domain before routing — force an address family (e.g. IPv4 only).")),
                        ),
                      ],
                    ),
                  ),
                const Divider(),

                // ─── Режим: Resolve only ─────────────────────────────────
                RadioListTile<bool>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: true,
                  title: Text(getLocalText.s("Resolve only")),
                  subtitle: Text(getLocalText.s("Resolve, then fall through to the next rule.")),
                ),
                if (_resolveOnly)
                  Padding(
                    padding: const EdgeInsets.only(left: 44, bottom: 8),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: Colors.orange.withValues(alpha: 0.6)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded,
                              color: Colors.orange, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              getLocalText.s("Advanced: this rule resolves but does not route. If no later rule matches, traffic goes to Final."),
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // ─── Единая панель Resolve options ───────────────────────────
          if (_resolveActive) ...[
            const SizedBox(height: 8),
            Text(getLocalText.s("Resolve options"),
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _strategies.contains(_strategy) ? _strategy : '',
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: getLocalText.s("Strategy"),
                isDense: true,
              ),
              items: [
                DropdownMenuItem(
                    value: '', child: Text(getLocalText.s("(inherit DNS strategy)"))),
                const DropdownMenuItem(
                    // l10n-exempt: wire strategy value shown as-is
                    value: 'prefer_ipv4', child: Text('prefer_ipv4')),
                const DropdownMenuItem(
                    // l10n-exempt: wire strategy value shown as-is
                    value: 'prefer_ipv6', child: Text('prefer_ipv6')),
                const DropdownMenuItem(
                    // l10n-exempt: wire strategy value shown as-is
                    value: 'ipv4_only', child: Text('ipv4_only')),
                const DropdownMenuItem(
                    // l10n-exempt: wire strategy value shown as-is
                    value: 'ipv6_only', child: Text('ipv6_only')),
              ],
              onChanged: (v) => setState(() => _strategy = v ?? ''),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _serverTag,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: getLocalText.s("DNS server"),
                isDense: true,
              ),
              items: [
                DropdownMenuItem(
                    value: '', child: Text(getLocalText.s("(auto — route DNS)"))),
                for (final tag in widget.controller.dnsServerTags)
                  DropdownMenuItem(value: tag, child: Text(tag)),
                // Сохранённый tag, которого нет в текущем списке (сервер
                // удалили/переименовали) — показываем честно, не маскируем
                // под «(auto)». Билдер-heal снимет его, если не доживёт.
                if (_serverTag.isNotEmpty &&
                    !widget.controller.dnsServerTags.contains(_serverTag))
                  DropdownMenuItem(
                      value: _serverTag,
                      child: Text(getLocalText.s("%s (missing)", _serverTag))),
              ],
              onChanged: (v) => setState(() => _serverTag = v ?? ''),
            ),
            const SizedBox(height: 4),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(getLocalText.s("Advanced DNS options"),
                  style: theme.textTheme.titleSmall),
              children: [
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _disableCache,
                  onChanged: (v) => setState(() => _disableCache = v),
                  title: Text(getLocalText.s("Disable cache")),
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _disableOptimisticCache,
                  onChanged: (v) =>
                      setState(() => _disableOptimisticCache = v),
                  title: Text(getLocalText.s("Disable optimistic cache")),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _ttlCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: getLocalText.s("Rewrite TTL"),
                    hintText: getLocalText.s("seconds, empty = keep"),
                    isDense: true,
                    errorText: _ttlError,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _timeoutCtrl,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: getLocalText.s("Query timeout"),
                    hintText: getLocalText.s("e.g. 5s, empty = default"),
                    isDense: true,
                    errorText: _timeoutError,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _subnetCtrl,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: getLocalText.s("Client subnet"),
                    hintText: getLocalText.s("e.g. 1.2.3.0/24, empty = off"),
                    isDense: true,
                    errorText: _subnetError,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ],

          // ─── Preview ────────────────────────────────────────────────
          const SizedBox(height: 12),
          Text(getLocalText.s("Preview (route.rules)"),
              style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _previewText(),
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontFamily: 'monospace'),
            ),
          ),

          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(getLocalText.s("Cancel")),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _hasErrors ? null : _done,
                child: Text(getLocalText.s("Done")),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
