import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/format_utils.dart';
import '../../../services/l10n/locale_controller.dart';
import '../../../services/relative_time.dart';
import '../../../services/workspaces/workspace_controller.dart';
import '../../../services/workspaces/workspace_store.dart';
import '../../../widgets/app_bottom_sheet.dart';

/// §417 — кнопка справа от «L×Box»: имя текущего workspace и попап с двумя
/// разделами — Load (слоты, у каждого меню «⋮»: переименовать / удалить) и
/// Save (Save as…). Отдельного экрана управления нет.
///
/// Загрузка идёт через [WorkspaceController.load]; на её время поверх
/// Navigator'а висит модальный прогресс. Маршрут прогресса живёт в
/// `MaterialApp`, а не в `HomeScreen`, поэтому переживает пересоздание
/// экрана — закрываем его через сохранённый `NavigatorState`.
class WorkspaceMenuButton extends StatelessWidget {
  const WorkspaceMenuButton({super.key, required this.stopVpn});

  /// Колбэк экрана: остановить пробы и туннель, вернуть «был ли поднят».
  final Future<bool> Function() stopVpn;

  @override
  Widget build(BuildContext context) {
    final ws = WorkspaceController.I;
    return AnimatedBuilder(
      animation: ws,
      builder: (context, _) => TextButton.icon(
        onPressed: ws.busy ? null : () => _openSheet(context),
        icon: const Icon(Icons.expand_more, size: 18),
        iconAlignment: IconAlignment.end,
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 140),
          child: Text(
            workspaceDisplayName(ws.current),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  Future<void> _openSheet(BuildContext context) async {
    final ws = WorkspaceController.I;
    await ws.refresh();
    final sizes = <String, int>{
      for (final s in ws.slots) s.name: await WorkspaceStore.I.slotSizeBytes(s.name),
    };
    if (!context.mounted) return;
    final action = await showAppBottomSheet<_SheetAction>(
      context: context,
      showDragHandle: true,
      builder: (_) => _WorkspaceSheet(sizes: sizes),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case _LoadAction(:final name):
        await _load(context, name);
      case _SaveAsAction():
        await _saveAs(context);
      case _RenameAction(:final name):
        await _rename(context, name);
      case _DeleteAction(:final name):
        await _delete(context, name);
    }
  }

  Future<void> _load(BuildContext context, String name) async {
    final ws = WorkspaceController.I;
    if (name == ws.current) return;
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(getLocalText.s("Loading workspace…"))),
            ],
          ),
        ),
      ),
    ));
    try {
      final outcome = await ws.load(name, stopVpn: stopVpn);
      if (outcome == WorkspaceLoadOutcome.loaded) {
        messenger.showSnackBar(SnackBar(
          content: Text(getLocalText.s(
              "Workspace “%s” loaded", workspaceDisplayName(name))),
        ));
      }
    } on WorkspaceError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(workspaceErrorText(e))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(getLocalText.s("Failed to load workspace: %s", '$e')),
      ));
    } finally {
      nav.pop();
    }
  }

  Future<void> _saveAs(BuildContext context) async {
    final ws = WorkspaceController.I;
    final messenger = ScaffoldMessenger.of(context);
    // У current ещё нет папки (первое использование) — предлагаем его имя.
    final hasFolder = ws.slots.any((s) => s.name == ws.current);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => WorkspaceNameDialog(initial: hasFolder ? '' : ws.current),
    );
    if (name == null || !context.mounted) return;
    if (ws.slots.any((s) => s.name == name)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(getLocalText.s("Overwrite “%s”?", name)),
          content: Text(getLocalText.s(
              "A workspace with this name already exists. Its saved state will be replaced.")),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(getLocalText.s("Cancel")),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(getLocalText.s("Overwrite")),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await ws.saveAs(name);
      messenger.showSnackBar(SnackBar(
        content: Text(getLocalText.s("Saved as “%s”", name)),
      ));
    } on WorkspaceError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(workspaceErrorText(e))));
    }
  }

  Future<void> _rename(BuildContext context, String name) async {
    final messenger = ScaffoldMessenger.of(context);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => WorkspaceNameDialog(
        initial: name,
        title: getLocalText.s("Rename"),
      ),
    );
    if (newName == null || newName == name) return;
    try {
      await WorkspaceController.I.rename(name, newName);
    } on WorkspaceError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(workspaceErrorText(e))));
    }
  }

  Future<void> _delete(BuildContext context, String name) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s(
            "Delete workspace “%s”?", workspaceDisplayName(name))),
        content: Text(getLocalText.s(
            "Its saved state will be removed. This cannot be undone.")),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(getLocalText.s("Delete")),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await WorkspaceController.I.delete(name);
    } on WorkspaceError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(workspaceErrorText(e))));
    }
  }
}

/// «Default» локализуется, имена пользователя — как есть.
String workspaceDisplayName(String name) =>
    name == WorkspaceStore.defaultName ? getLocalText.s("Default") : name;

String workspaceNameErrorText(WorkspaceNameError e) => switch (e) {
      WorkspaceNameError.empty => getLocalText.s("Name is empty"),
      WorkspaceNameError.tooLong => getLocalText.s("Name is too long"),
      WorkspaceNameError.forbiddenChars =>
        getLocalText.s("Name must not contain / or \\"),
      WorkspaceNameError.leadingDot =>
        getLocalText.s("Name must not start with a dot"),
    };

String workspaceErrorText(WorkspaceError e) => switch (e.kind) {
      WorkspaceErrorKind.notFound => getLocalText.s("Workspace not found"),
      WorkspaceErrorKind.exists =>
        getLocalText.s("A workspace with this name already exists"),
      WorkspaceErrorKind.isCurrent =>
        getLocalText.s("The current workspace cannot be deleted"),
      WorkspaceErrorKind.invalidName => e.nameError == null
          ? getLocalText.s("Name is empty")
          : workspaceNameErrorText(e.nameError!),
    };

sealed class _SheetAction {
  const _SheetAction();
}

class _LoadAction extends _SheetAction {
  const _LoadAction(this.name);
  final String name;
}

class _SaveAsAction extends _SheetAction {
  const _SaveAsAction();
}

class _RenameAction extends _SheetAction {
  const _RenameAction(this.name);
  final String name;
}

class _DeleteAction extends _SheetAction {
  const _DeleteAction(this.name);
  final String name;
}

class _WorkspaceSheet extends StatelessWidget {
  const _WorkspaceSheet({required this.sizes});

  final Map<String, int> sizes;

  @override
  Widget build(BuildContext context) {
    final ws = WorkspaceController.I;
    final theme = Theme.of(context);
    final now = DateTime.now();
    final slots = [...ws.slots]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    // current без папки (до первого Save as) — показываем первым, без даты
    // и без меню: переименовывать/удалять ещё нечего.
    final currentHasFolder = slots.any((s) => s.name == ws.current);

    Widget section(String title) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            title,
            style: theme.textTheme.labelLarge
                ?.copyWith(color: theme.colorScheme.primary),
          ),
        );

    Widget slotTile({required String name, WorkspaceSlot? slot}) {
      final isCurrent = name == ws.current;
      final size = sizes[name];
      final subtitle = slot == null
          ? null
          : [
              relativeTime(now, slot.savedAt),
              if (size != null) formatBytes(size, spaced: true),
            ].join(' · ');
      return ListTile(
        leading: Icon(
          isCurrent ? Icons.radio_button_checked : Icons.radio_button_off,
          color: isCurrent ? theme.colorScheme.primary : null,
        ),
        title: Text(workspaceDisplayName(name)),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: slot == null
            ? null
            : PopupMenuButton<_SheetAction>(
                onSelected: (a) => Navigator.pop(context, a),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: _RenameAction(name),
                    child: Text(getLocalText.s("Rename")),
                  ),
                  // current — адрес автосохранения, удалить нельзя.
                  PopupMenuItem(
                    value: _DeleteAction(name),
                    enabled: !isCurrent,
                    child: Text(getLocalText.s("Delete")),
                  ),
                ],
              ),
        onTap: () => Navigator.pop(context, _LoadAction(name)),
      );
    }

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(getLocalText.s("Workspaces"),
                style: theme.textTheme.titleMedium),
          ),
          section(getLocalText.s("Load")),
          if (!currentHasFolder) slotTile(name: ws.current),
          for (final s in slots) slotTile(name: s.name, slot: s),
          const Divider(height: 8),
          section(getLocalText.s("Save")),
          ListTile(
            leading: const Icon(Icons.save_as_outlined),
            title: Text(getLocalText.s("Save as…")),
            onTap: () => Navigator.pop(context, const _SaveAsAction()),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Диалог имени слота: валидация [WorkspaceStore.validateName] на лету,
/// кнопка Save недоступна при невалидном имени. Возвращает trimmed имя.
class WorkspaceNameDialog extends StatefulWidget {
  const WorkspaceNameDialog({super.key, this.initial = '', this.title});

  final String initial;
  final String? title;

  @override
  State<WorkspaceNameDialog> createState() => _WorkspaceNameDialogState();
}

class _WorkspaceNameDialogState extends State<WorkspaceNameDialog> {
  late final TextEditingController _ctrl;
  WorkspaceNameError? _error;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
    _error = WorkspaceStore.validateName(widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_error != null) return;
    Navigator.pop(context, _ctrl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title ?? getLocalText.s("Save as…")),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLength: WorkspaceStore.nameMaxLength,
        decoration: InputDecoration(
          labelText: getLocalText.s("Workspace name"),
          errorText: _error == null || _ctrl.text.isEmpty
              ? null
              : workspaceNameErrorText(_error!),
        ),
        onChanged: (v) =>
            setState(() => _error = WorkspaceStore.validateName(v)),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(getLocalText.s("Cancel")),
        ),
        FilledButton(
          onPressed: _error == null ? _submit : null,
          child: Text(getLocalText.s("Save")),
        ),
      ],
    );
  }
}
