// §262 — лист-подсказка при деградации DNS (открывается тапом по
// [DnsHealthBanner]).
//
// Детектор здоровья DNS в профайлере зажёг баннер: массовые fail-резолвы при
// живой связи. Лист НЕ меняет настройки молча — он объясняет, что можно сделать,
// и ведёт в нужный экран, где юзер решает сам:
//
//   • Open DNS settings — DNS-серверы (их outbound-Направление) + final resolver.
//   • Enable FakeIP — каталог пресетов (таб Presets в Routing), где юзер
//     добавляет FakeIP. Кнопка видна, только пока пресет не активирован.
//
// Навигация требует контроллеры (subController/homeController). Если их нет
// (лист открыт вне home-контекста) — показываем только текст-подсказку.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/home_controller.dart';
import '../../controllers/subscription_controller.dart';
import '../../models/custom_rule.dart';
import '../../services/settings_storage.dart';
import '../dns_settings_screen.dart';
import '../routing_screen.dart';
import '../../services/l10n/locale_controller.dart';
import '../../widgets/app_bottom_sheet.dart';

/// Открыть лист-подсказку (выезжает снизу вверх). Контроллеры нужны для
/// навигационных кнопок; без них лист чисто информационный.
Future<void> showDnsHealthSheet(
  BuildContext context, {
  SubscriptionController? subController,
  HomeController? homeController,
}) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _DnsHealthSheet(
      subController: subController,
      homeController: homeController,
    ),
  );
}

class _DnsHealthSheet extends StatefulWidget {
  const _DnsHealthSheet({this.subController, this.homeController});

  final SubscriptionController? subController;
  final HomeController? homeController;

  @override
  State<_DnsHealthSheet> createState() => _DnsHealthSheetState();
}

class _DnsHealthSheetState extends State<_DnsHealthSheet> {
  /// Активирован ли уже пресет FakeIP — прячет кнопку «Enable FakeIP».
  /// null = ещё считаем (async).
  bool? _fakeIpActive;

  bool get _canNavigate =>
      widget.subController != null && widget.homeController != null;

  @override
  void initState() {
    super.initState();
    unawaited(_checkFakeIp());
  }

  Future<void> _checkFakeIp() async {
    final rules = await SettingsStorage.getCustomRules();
    final active = rules.any(
      (r) => r is CustomRulePreset && r.presetId == 'fakeip' && r.enabled,
    );
    if (mounted) setState(() => _fakeIpActive = active);
  }

  void _openDnsSettings() {
    final sub = widget.subController;
    final home = widget.homeController;
    if (sub == null || home == null) return;
    Navigator.pop(context);
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) =>
          DnsSettingsScreen(subController: sub, homeController: home),
    ));
  }

  void _openFakeIpPreset() {
    final sub = widget.subController;
    final home = widget.homeController;
    if (sub == null || home == null) return;
    Navigator.pop(context);
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RoutingScreen(
        subController: sub,
        homeController: home,
        initialPresetsTab: true,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Кнопку FakeIP показываем, только когда точно знаем, что он не активен.
    final showFakeIp = _canNavigate && _fakeIpActive == false;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Icon(Icons.dns_outlined, color: cs.error, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    getLocalText.s("DNS queries are failing"),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              getLocalText.s("Names are not resolving while the connection is alive — the DNS path looks blocked. In DNS settings you can:\n  • route your DNS servers through the VPN — set their outbound to a direction so queries go inside the tunnel;\n  • switch the final resolver to your operator's DNS — works everywhere, but your operator sees every domain.\nFakeIP resolves names inside the tunnel with placeholder IPs — no pre-tunnel DNS leaks."),
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            if (_canNavigate) ...[
              FilledButton(
                onPressed: _openDnsSettings,
                child: Text(getLocalText.s("Open DNS settings")),
              ),
              if (showFakeIp) ...[
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _openFakeIpPreset,
                  child: Text(getLocalText.s("Enable FakeIP")),
                ),
              ],
            ],
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(getLocalText.s("Close")),
            ),
          ],
        ),
      ),
    );
  }
}
