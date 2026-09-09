import 'package:flutter/material.dart';

import '../../../controllers/subscription_controller.dart';
import '../../../models/direction.dart';
import '../../../models/server_list.dart';
import '../../../services/subscription/input_helpers.dart';
import '../../../services/subscription/user_agent.dart';
import '../../../widgets/detour_target_picker.dart' show detourDirectionDisplay;
import '../detour_mode.dart';
import '../subscription_detail_format.dart';
import '../../../services/l10n/locale_controller.dart';
import '../../../widgets/safe_bottom.dart';

/// Settings tab: tag-prefix field, detour-mode radio group (+ sub-options) and
/// the subscription-info block. Extracted verbatim from `_buildSettingsTab` /
/// `_buildSubscriptionInfo`. All mutation/persist/dialog logic stays in the
/// screen and is wired in via the callbacks below.
class SubscriptionSettingsTab extends StatelessWidget {
  const SubscriptionSettingsTab({
    super.key,
    required this.entry,
    this.folderMode = false,
    this.directions = const [],
    this.detourPathHopsOf,
    required this.hasDetour,
    required this.detourMode,
    required this.onTagPrefixChanged,
    this.onTagPrefixCommitted,
    required this.onSetDetourMode,
    required this.onRegisterDetourServersChanged,
    required this.onRegisterDetourInAutoChanged,
    required this.onShowOverrideDetourPicker,
    required this.onReplaceDetourChainChanged,
    required this.onCopyUrl,
    required this.onShowIntervalPicker,
    required this.onShowOnUpdateActionPicker,
    this.autoReloadOnChange = false,
    required this.onRefreshNow,
    required this.onEditSource,
    // §289 — per-subscription fetch identity (nullable: папка не рисует секцию).
    this.onToggleCustomIdentity,
    this.onEditIdentityUserAgent,
    this.onIdentitySendHwidChanged,
    this.onEditIdentityHwid,
    this.onRegenerateIdentityHwid,
    this.onEditIdentityDeviceOs,
    this.onEditIdentityVerOs,
    this.onEditIdentityDeviceModel,
  });

  final SubscriptionEntry entry;

  /// §338 — глобальная галка «автоперезапуск при смене настроек» включена: она
  /// перекрывает per-subscription выбор, строку «On update» не рисуем. Поле
  /// подписки при этом не тронуто — выключение галки вернёт её значение.
  final bool autoReloadOnChange;

  /// §239 — true для папки (§234): адаптированные detour-тексты («servers'
  /// own detours» вместо «subscription detour servers»).
  final bool folderMode;

  /// §248 — Направления для подписи «⚙ <label>» Направления override-цели
  /// (экран грузит SettingsStorage.getDirections и передаёт сюда).
  final List<Direction> directions;

  /// §252 — разворот цели в цепочку хопов «как пакет пойдёт» (detourPathHops
  /// с controller'ом экрана). null → показываем один хоп (как раньше).
  final List<String> Function(String stored)? detourPathHopsOf;
  final bool hasDetour;
  final DetourMode detourMode;

  final ValueChanged<String> onTagPrefixChanged;

  /// §393 A6 — префикс ДОПЕЧАТАН (поле потеряло фокус либо submit), а не
  /// «изменился ещё на один символ». Каскад на Направления считается только
  /// здесь: [onTagPrefixChanged] стреляет на КАЖДОЕ нажатие, и heal по нему
  /// переписал бы regex-фильтры промежуточными огрызками (`RU:` → `R` → `RU`
  /// при наборе `RU: v2`), уничтожив их за несколько символов.
  final ValueChanged<String>? onTagPrefixCommitted;
  final ValueChanged<DetourMode> onSetDetourMode;
  final ValueChanged<bool> onRegisterDetourServersChanged;
  final ValueChanged<bool> onRegisterDetourInAutoChanged;
  final VoidCallback onShowOverrideDetourPicker;
  final ValueChanged<bool> onReplaceDetourChainChanged;
  final VoidCallback onCopyUrl;
  final VoidCallback onShowIntervalPicker;

  /// §323 — пикер реакции на авто-обновление.
  final VoidCallback onShowOnUpdateActionPicker;
  final VoidCallback onRefreshNow;
  final VoidCallback onEditSource; // §129 — сменить источник (online↔file)

  // §289 — Fetch identity (секция «Custom identity»). Nullable: секция видна
  // только для SubscriptionServers, папка (folderMode) их не передаёт и не
  // рисует блок — колбэки не зовутся.
  final ValueChanged<bool>? onToggleCustomIdentity;
  final VoidCallback? onEditIdentityUserAgent;
  final ValueChanged<bool>? onIdentitySendHwidChanged;
  final VoidCallback? onEditIdentityHwid;
  final VoidCallback? onRegenerateIdentityHwid;
  final VoidCallback? onEditIdentityDeviceOs;
  final VoidCallback? onEditIdentityVerOs;
  final VoidCallback? onEditIdentityDeviceModel;

  /// §248 — подпись override-цели: тег detour-Направления (или его auto-двойника)
  /// → «⚙ <label>»; Направление не найден → сырой тег. Интра-омоним папки (bare-тег
  /// собственного члена) побеждает Направление-тёзку — это ссылка на члена
  /// (приоритет bareIndex в FolderDetourPlan), показываем как тег.
  String _overrideDisplay() {
    final stored = entry.overrideDetour;
    final list = entry.list;
    if (folderMode && list is FolderServers) {
      for (final m in list.members) {
        if (m.node?.tag == stored) return stored;
      }
    }
    return detourDirectionDisplay(stored, directions);
  }

  /// §252 — цепочка хопов цели по ходу пакета (или один хоп, если экран не
  /// прокинул разворот).
  String _overridePath() {
    final hops = detourPathHopsOf?.call(entry.overrideDetour);
    if (hops == null || hops.isEmpty) return _overrideDisplay();
    return hops.join(' → ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16).withSafeBottom(context),
      children: [
        Text(getLocalText.s("Tag prefix"), style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        )),
        const SizedBox(height: 4),
        Text(
          folderMode
              ? getLocalText.s("Prefix applied to every server tag in this folder (e.g. \"BL:\" → \"BL: Frankfurt\"). Lets a routing direction match the whole folder by regex.")
              : getLocalText.s("Prefix applied to every tag from this subscription (e.g. \"BL:\" → \"BL: Frankfurt\"). Used to distinguish servers from different subscriptions and resolve name collisions."),
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          // §393 A6 — Focus поверх поля: уход фокуса = «допечатал», момент,
          // когда каскад на Направления считать безопасно (см.
          // [onTagPrefixCommitted]).
          child: Focus(
            onFocusChange: (has) {
              if (!has) onTagPrefixCommitted?.call(entry.tagPrefix);
            },
            child: TextFormField(
              initialValue: entry.tagPrefix,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: getLocalText.s("Prefix"),
                hintText: getLocalText.s("empty = no prefix"),
                isDense: true,
              ),
              // done снимает фокус → коммит приходит одним путём (через
              // Focus выше). Свой onFieldSubmitted тут дал бы ВТОРОЙ вызов
              // на то же событие.
              textInputAction: TextInputAction.done,
              onChanged: onTagPrefixChanged,
            ),
          ),
        ),
        const SizedBox(height: 24),
        if (hasDetour) ...[
          Text(getLocalText.s("Detour servers"), style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          )),
          const Divider(),
          // Тернарный mode (radio): три mutually-exclusive варианта над парой
          // полей entry.{useDetourServers, overrideDetour}. Mapping:
          //   use      → useDetour=true,  override=''
          //   override → useDetour=true,  override='<tag>'
          //   none     → useDetour=false, override=''
          // register'ы (sub-options для mode=use) хранятся независимо, не
          // обнуляются при переключении mode'а — юзер вернётся в use, флаги
          // на месте.
          RadioGroup<DetourMode>(
            groupValue: detourMode,
            onChanged: (m) => onSetDetourMode(m!),
            child: Column(children: [
              RadioListTile<DetourMode>(
                value: DetourMode.use,
                title: Text(folderMode
                    ? getLocalText.s("Use servers' own detours")
                    : getLocalText.s("Use subscription detour servers")),
                subtitle: Text(folderMode
                    ? getLocalText.s("Members connect through their personal detours")
                    : getLocalText.s("Nodes connect through detour servers")),
              ),
              // §096 — register-тоглы под Use (нативные детуры используются).
              if (detourMode == DetourMode.use) _registerToggles(context),
              RadioListTile<DetourMode>(
                value: DetourMode.override,
                title: Text(getLocalText.s("Add detour")),
                subtitle: Text(entry.overrideDetour.isEmpty
                    ? getLocalText.s("Append an outbound to the end of the chain")
                    : entry.replaceDetourChain
                        ? getLocalText.s("Replace all → %s", _overrideDisplay())
                        : getLocalText.s("Fill missing → %s", _overrideDisplay())),
              ),
              // Sub-tiles под «Add detour»: outbound picker + выбор режима.
              // §073/§245: тот же bool replaceDetourChain, но вместо
              // невнятного toggle — два явных radio-режима:
              //   Replace all  → replaceDetourChain=true  (дропнуть цепочки)
              //   Fill missing → replaceDetourChain=false (default, append)
              if (detourMode == DetourMode.override) ...[
                Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: ListTile(
                    title: Text(getLocalText.s("Outbound")),
                    subtitle: Text(entry.overrideDetour.isEmpty
                        ? getLocalText.s("(tap to choose)")
                        : _overrideDisplay()),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: onShowOverrideDetourPicker,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: RadioGroup<bool>(
                    groupValue: entry.replaceDetourChain,
                    onChanged: (v) => onReplaceDetourChainChanged(v!),
                    child: Column(children: [
                      RadioListTile<bool>(
                        value: true,
                        title: Text(getLocalText.s("Replace all")),
                        subtitle: Text(folderMode
                            ? getLocalText.s("Drop existing detours — every member connects through this outbound")
                            : getLocalText.s("Drop existing detours — every node connects through this outbound")),
                      ),
                      RadioListTile<bool>(
                        value: false,
                        title: Text(getLocalText.s("Fill missing")),
                        subtitle: Text(folderMode
                            ? getLocalText.s("Members with their own detour keep it; this outbound is set only where none is defined")
                            : getLocalText.s("Nodes with their own detour keep it; this outbound is set only where none is defined")),
                      ),
                    ]),
                  ),
                ),
                // §096 — в режиме Fill missing (append) нативные детуры
                // подписки сохраняются в цепочке → register-тоглы
                // осмысленны и тут.
                if (!entry.replaceDetourChain) _registerToggles(context),
              ],
              RadioListTile<DetourMode>(
                value: DetourMode.none,
                title: Text(getLocalText.s("Don't use detour servers")),
                subtitle: Text(getLocalText.s("Nodes connect directly, detour skipped")),
              ),
            ]),
          ),
        ] else ...[
          // §111 — у подписки нет родных detour-цепочек: полный radio
          // (Use/Add/None) вырождается — Use≡None, register-тоглы и Replace
          // неприменимы. Вместо него один пикер поверх тех же полей
          // DetourPolicy: выбор тага → useDetourServers=true + override
          // (builder: APPEND на пустой цепочке = 1-hop), None → override=''.
          Text(getLocalText.s("Detour"), style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          )),
          const SizedBox(height: 4),
          Text(
            folderMode
                ? getLocalText.s("Servers in this folder have no detours yet. You can still route all of them through one of your servers, or set personal detours per server (tap a server on the Servers tab).")
                : getLocalText.s("This subscription has no detour servers of its own. You can still route all its nodes through one of your servers."),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.alt_route, size: 20),
            title: Text(getLocalText.s("Detour server")),
            subtitle: Text(entry.overrideDetour.isEmpty
                ? getLocalText.s("None — nodes connect directly")
                // detour — ВХОДНОЙ (трафик идёт через него ПЕРВЫМ, потом в
                // ноды подписки, потом наружу). §252 — полная цепочка «как
                // пакет пойдёт»: цель → её собственный detour → … (та же
                // детализация, что у одиночного сервера в Node Settings).
                : getLocalText.s("Phone → %s → Nodes → Internet", _overridePath())),
            trailing: const Icon(Icons.chevron_right),
            onTap: onShowOverrideDetourPicker,
          ),
        ],
        if (entry.list is SubscriptionServers) ...[
          const SizedBox(height: 24),
          Text(getLocalText.s(1, "Subscription"), style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          )),
          const Divider(),
          _buildSubscriptionInfo(context, theme),
          const SizedBox(height: 24),
          // §289 — per-subscription fetch identity (Default/Custom override).
          Text(getLocalText.s("Fetch identity"), style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          )),
          const Divider(),
          ..._buildFetchIdentity(context, theme),
        ],
      ],
    );
  }

  /// §289 — секция Fetch identity подписки. Тумблер «Custom identity» (off =
  /// глобальная идентичность §118), при Custom — полный блок полей (UA, HWID,
  /// device-meta), читающий значения из `entry.identity`. Форма полей —
  /// зеркало глобального таба (app_settings_screen → Subscriptions).
  List<Widget> _buildFetchIdentity(BuildContext context, ThemeData theme) {
    final cs = theme.colorScheme;
    final id = entry.identity; // null = Default
    return [
      SwitchListTile(
        secondary: const Icon(Icons.badge_outlined),
        title: Text(getLocalText.s("Custom identity")),
        subtitle: Text(getLocalText.s(
            "Override global fetch identity for this subscription.")),
        value: entry.hasCustomIdentity,
        onChanged: onToggleCustomIdentity,
      ),
      if (id != null) ...[
        ListTile(
          leading: const Icon(Icons.badge_outlined),
          title: Text(getLocalText.s("Custom User-Agent")),
          subtitle: Text(
            id.userAgent.isEmpty
                ? getLocalText.s("Default · %s", resolveSubscriptionUserAgent())
                : id.userAgent,
            style: TextStyle(
              fontStyle: id.userAgent.isEmpty ? FontStyle.italic : null,
            ),
          ),
          trailing: const Icon(Icons.edit_outlined),
          onTap: onEditIdentityUserAgent,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            getLocalText.s("Some panels return the config by a substring in the User-Agent — a custom UA without the \"LxBox\" token may yield an unsupported format and break the update. Change only if you know why."),
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ),
        SwitchListTile(
          title: Text(getLocalText.s("Send HWID")),
          subtitle: Text(getLocalText.s("Send x-hwid + device headers on every subscription fetch — for panels with HWID device limits (Remnawave). Off by default.")),
          secondary: const Icon(Icons.devices_outlined),
          value: id.sendHwid,
          onChanged: onIdentitySendHwidChanged,
        ),
        if (id.sendHwid) ...[
          _editRow(
            context,
            icon: Icons.tag,
            label: 'HWID · x-hwid',
            value: id.hwid,
            monospace: true,
            onEdit: onEditIdentityHwid,
            extra: IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: getLocalText.s("Regenerate"),
              onPressed: onRegenerateIdentityHwid,
            ),
          ),
          _editRow(context,
              icon: Icons.android, label: 'x-device-os', value: id.deviceOs,
              onEdit: onEditIdentityDeviceOs),
          _editRow(context,
              icon: Icons.numbers, label: 'x-ver-os', value: id.verOs,
              onEdit: onEditIdentityVerOs),
          _editRow(context,
              icon: Icons.phone_android,
              label: 'x-device-model',
              value: id.deviceModel,
              onEdit: onEditIdentityDeviceModel),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              getLocalText.s("These headers identify your device to the panel. Defaults come from the device — override any of them (empty = device default)."),
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ],
    ];
  }

  /// §289 — строка редактируемого заголовка идентичности (зеркало `_editRow`
  /// глобального таба). `onEdit`/`extra` — nullable-колбэки родителя.
  Widget _editRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback? onEdit,
    bool monospace = false,
    Widget? extra,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(
        value.isEmpty ? getLocalText.s("(empty)") : value,
        style: TextStyle(
          fontFamily: monospace ? 'monospace' : null,
          fontSize: monospace ? 12 : null,
          color: value.isEmpty
              ? Theme.of(context).colorScheme.onSurfaceVariant
              : null,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?extra,
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20),
            tooltip: getLocalText.s("Edit"),
            onPressed: onEdit,
          ),
        ],
      ),
    );
  }

  /// §096/§026 — register-тоглы detour-серверов. Показываются когда нативные
  /// детуры в игре: режим **Use** ИЛИ **Add detour + Fill missing** (append).
  /// Прячутся при Replace all / None (нативных детуров нет — регистрировать
  /// нечего).
  /// Делают detour-сервера видимыми как ноды (selector) / в ✨auto. Флаги
  /// хранятся независимо от режима — переключение Use↔Add detour их не теряет.
  Widget _registerToggles(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 24),
        child: Column(children: [
          SwitchListTile(
            title: Text(getLocalText.s("Register detour servers")),
            subtitle: Text(getLocalText.s("Add detour servers to proxy groups (visible in node list)")),
            value: entry.registerDetourServers,
            onChanged: onRegisterDetourServersChanged,
          ),
          SwitchListTile(
            title: Text(getLocalText.s("Register detour in auto group")),
            subtitle: Text(getLocalText.s("Include detour servers in auto-proxy-out urltest")),
            value: entry.registerDetourInAuto,
            onChanged: onRegisterDetourInAutoChanged,
          ),
        ]),
      );

  Widget _buildSubscriptionInfo(BuildContext context, ThemeData theme) {
    final list = entry.list as SubscriptionServers;
    final cs = theme.colorScheme;
    final label = statusLabel(list);
    final color = statusColor(list, cs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // §129 — источник подписки. Клик по строке → сменить источник
        // (online URL ↔ файл). Для онлайн — copy-иконка справа (копировать URL);
        // для файла показываем имя (снапшот в кэше, сырого URL нет).
        Builder(builder: (context) {
          final isFile = isFileSubscription(list.url);
          return ListTile(
            leading: Icon(isFile ? Icons.insert_drive_file_outlined : Icons.link,
                size: 20),
            // l10n-exempt: 'URL' is locale-invariant
            title: Text(isFile ? getLocalText.s("Source: local file") : 'URL'),
            subtitle: Text(isFile ? entry.displayName : list.url,
                maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: isFile
                ? const Icon(Icons.edit, size: 18)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.content_copy, size: 18),
                        tooltip: getLocalText.s("Copy URL"),
                        visualDensity: VisualDensity.compact,
                        onPressed: onCopyUrl,
                      ),
                      const Icon(Icons.edit, size: 18),
                    ],
                  ),
            onTap: onEditSource,
          );
        }),
        // §129 — Update interval: -1 = никогда (игнор сервера); 0 = respect
        // server (сами не по расписанию); >0 = раз в N часов.
        ListTile(
          leading: const Icon(Icons.sync, size: 20),
          title: Text(getLocalText.s("Update interval")),
          subtitle: Text(switch (list.updateIntervalHours) {
            < 0 => getLocalText.s("Don't auto-update (manual only)"),
            0 => getLocalText.s("Never (respect server) — manual only unless server sets one"),
            final h => getLocalText.s("%1\$dh (auto-refresh every %2\$s)", h, intervalHuman(h)),
          }),
          trailing: const Icon(Icons.edit, size: 18),
          onTap: onShowIntervalPicker,
        ),
        // §323 — что делать после обновления подписки.
        // §338 — при включённой глобальной галке «автоперезапуск при смене
        // настроек» выбор перекрыт (всё применяется сразу) → строку скрываем.
        if (!autoReloadOnChange)
          ListTile(
            leading: const Icon(Icons.play_circle_outline, size: 20),
            title: Text(getLocalText.s("On update")),
            subtitle: Text(switch (list.onUpdateAction) {
              SubscriptionOnUpdateAction.rebuild =>
                getLocalText.s("Rebuild config — apply manually"),
              SubscriptionOnUpdateAction.reload =>
                getLocalText.s("Rebuild and reload core — brief connection drop"),
              SubscriptionOnUpdateAction.none =>
                getLocalText.s("Do nothing — apply on next rebuild"),
            }),
            trailing: const Icon(Icons.edit, size: 18),
            onTap: onShowOnUpdateActionPicker,
          ),
        ListTile(
          leading: Icon(statusIcon(list), size: 20, color: color),
          title: Text(label, style: TextStyle(color: color)),
          subtitle: Text(subscriptionStatusSubtitle(list)),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: OutlinedButton.icon(
            onPressed: onRefreshNow,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(getLocalText.s("Refresh now")),
          ),
        ),
      ],
    );
  }
}
