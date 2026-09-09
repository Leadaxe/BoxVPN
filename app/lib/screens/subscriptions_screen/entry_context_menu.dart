import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../controllers/subscription_controller.dart';
import '../../models/server_list.dart';
import '../../models/ui_msg.dart';
import '../../services/subscription/auto_updater.dart';
import '../../services/subscription/input_helpers.dart';
import 'folder_picker.dart';
import '../../services/l10n/locale_controller.dart';
import '../../services/file_import.dart';
import '../../widgets/app_bottom_sheet.dart';

/// Long-press bottom-sheet для записи подписки/сервера. Поведение 1:1 с
/// прежним `_showContextMenu` — копировать URL, share, update,
/// reset fail-count, delete-with-confirm. §234 — у папки своё меню
/// (rename/delete), у одиночного сервера + «Move to folder…».
void showEntryContextMenu(
  BuildContext context,
  int index,
  SubscriptionEntry entry, {
  required SubscriptionController subController,
  required AutoUpdater autoUpdater,
}) {
  if (entry.list is FolderServers) {
    _showFolderContextMenu(context, index, entry, subController);
    return;
  }
  showAppBottomSheet(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.copy),
            title: Text(getLocalText.s("Copy URL")),
            onTap: () {
              final url = entry.url.isNotEmpty
                  ? entry.url
                  : entry.connections.isNotEmpty
                      ? entry.connections.first
                      : '';
              if (url.isNotEmpty) {
                Clipboard.setData(ClipboardData(text: url));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(getLocalText.s("URL copied"))),
                );
              }
              Navigator.pop(ctx);
            },
          ),
          // §347 — сразу системный share-sheet с полным URL, без
          // промежуточного диалога masked/full. Для file-подписки (§129)
          // пункт скрыт: `file:<uuid>` — локальный ключ кэша, шарить нечего.
          if (entry.url.isNotEmpty && !isFileSubscription(entry.url))
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: Text(getLocalText.s("Share URL…")),
              onTap: () async {
                Navigator.pop(ctx);
                await Share.share(entry.url, subject: 'LxBox subscription');
              },
            ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: Text(getLocalText.s("Update")),
            onTap: () {
              Navigator.pop(ctx);
              unawaited(subController.updateAt(index));
            },
          ),
          // §129 — сменить источник подписки (online URL ↔ локальный файл).
          // Транзакционно: старый источник сбрасывается только после успеха
          // нового (см. updateSourceAt). Для file-подписки это ещё и «обновить»
          // (выбрать файл заново).
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text(getLocalText.s("Edit source…")),
            onTap: () async {
              Navigator.pop(ctx);
              await showEditSourceDialog(context, index, entry, subController);
            },
          ),
          // Reset fail-count (night T8-1). Если провайдер вернулся в строй
          // после фриза (5 фейлов подряд → заморожено до app-restart),
          // юзер может руками разморозить без перезапуска.
          if (entry.url.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: Text(getLocalText.s("Reset fail count & retry")),
              onTap: () async {
                Navigator.pop(ctx);
                autoUpdater.resetFailCount(entry.url);
                await subController.updateAt(index);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(getLocalText.s("Fail count reset, retrying…"))),
                );
              },
            ),
          // §234 — одиночный сервер можно перенести в папку (личные
          // prefix/detour при этом заменяются папочными).
          if (entry.list is UserServer)
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: Text(getLocalText.s("Move to folder…")),
              onTap: () async {
                Navigator.pop(ctx);
                final folderIndex =
                    await showFolderPicker(context, subController);
                if (folderIndex == null || !context.mounted) return;
                // Индекс сервера по ссылке — создание новой папки в пикере
                // добавляет entry, а reorder мог сместить исходный index.
                final serverIndex = subController.entries.indexOf(entry);
                if (serverIndex < 0) return;
                final err = await subController.moveServerToFolder(
                    serverIndex, folderIndex);
                if (err != null && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(err.render())));
                }
              },
            ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
            title: Text(getLocalText.s("Delete"), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () async {
              Navigator.pop(ctx);
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (dCtx) => AlertDialog(
                  title: Text(getLocalText.s("Delete subscription?")),
                  content: Text(getLocalText.s("Remove \"%s\"?", entry.displayName)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(dCtx, false), child: Text(getLocalText.s("Cancel"))),
                    TextButton(
                      onPressed: () => Navigator.pop(dCtx, true),
                      style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                      child: Text(getLocalText.s("Delete")),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await subController.removeAt(index);
                          }
            },
          ),
        ],
      ),
    ),
  );
}

/// §234 — long-press меню папки: rename / delete (с выбором судьбы серверов).
void _showFolderContextMenu(
  BuildContext context,
  int index,
  SubscriptionEntry entry,
  SubscriptionController subController,
) {
  final folder = entry.list as FolderServers;
  showAppBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text(getLocalText.s("Rename…")),
            onTap: () async {
              Navigator.pop(ctx);
              if (!context.mounted) return;
              final name = await showFolderNameDialog(context,
                  initial: entry.name, title: getLocalText.s("Rename folder"));
              if (name == null) return;
              await subController.renameAt(index, name);
            },
          ),
          ListTile(
            leading: Icon(Icons.delete_outline,
                color: Theme.of(context).colorScheme.error),
            title: Text(getLocalText.s("Delete…"),
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () async {
              Navigator.pop(ctx);
              final choice = await showDialog<String>(
                context: context,
                builder: (dCtx) => AlertDialog(
                  title: Text(getLocalText.s("Delete folder?")),
                  content: Text(folder.members.isEmpty
                      ? getLocalText.s("Remove \"%s\"?", entry.displayName)
                      : getLocalText.plural(
                          "Folder \"%2\$s\" contains %1\$d servers.",
                          folder.members.length,
                          entry.displayName)),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dCtx),
                        child: Text(getLocalText.s("Cancel"))),
                    if (folder.members.isNotEmpty)
                      TextButton(
                        onPressed: () => Navigator.pop(dCtx, 'keep'),
                        child: Text(getLocalText.s("Keep servers")),
                      ),
                    TextButton(
                      onPressed: () => Navigator.pop(dCtx, 'all'),
                      style: TextButton.styleFrom(
                          foregroundColor:
                              Theme.of(dCtx).colorScheme.error),
                      child: Text(folder.members.isEmpty
                          ? getLocalText.s("Delete")
                          : getLocalText.s("Delete folder & servers")),
                    ),
                  ],
                ),
              );
              if (choice == null) return;
              await subController.deleteFolderAt(index,
                  keepServers: choice == 'keep');
            },
          ),
        ],
      ),
    ),
  );
}

/// §129 — диалог смены источника подписки: online URL ↔ локальный файл.
/// Переключатель режима; online → текст-поле URL, file → picker. Save зовёт
/// `updateSourceAt` (транзакционно: старый источник живёт, пока новый не удался).
Future<void> showEditSourceDialog(
  BuildContext context,
  int index,
  SubscriptionEntry entry,
  SubscriptionController subController,
) async {
  final wasFile = isFileSubscription(entry.url);
  var fileMode = wasFile;
  final urlCtl = TextEditingController(text: wasFile ? '' : entry.url);
  String? pickedBody; // тело выбранного файла (file-режим)
  String pickedName = wasFile ? entry.displayName : '';
  var busy = false;

  await showDialog<void>(
    context: context,
    builder: (dCtx) => StatefulBuilder(
      builder: (dCtx, setLocal) => AlertDialog(
        title: Text(getLocalText.s("Edit source")),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RadioGroup<bool>(
              groupValue: fileMode,
              onChanged: (v) => setLocal(() => fileMode = v ?? false),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<bool>(
                    value: false,
                    title: Text(getLocalText.s("Online URL")),
                    contentPadding: EdgeInsets.zero,
                  ),
                  RadioListTile<bool>(
                    value: true,
                    title: Text(getLocalText.s("Local file")),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (!fileMode)
              TextField(
                controller: urlCtl,
                decoration: InputDecoration(
                  labelText: getLocalText.s("Subscription URL"),
                  // l10n-exempt: URL scheme hint, locale-invariant
                  hintText: 'https://…',
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Text(
                      pickedBody == null
                          ? (pickedName.isEmpty
                              ? getLocalText.s("No file chosen")
                              : pickedName)
                          : pickedName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      // §372 — нет пикера (Android TV): подсказываем перейти
                      // в режим «Online URL», он тут же в диалоге.
                      final outcome = await pickFileSafely();
                      if (outcome is! PickedFiles) {
                        final problem = pickProblemText(outcome);
                        if (problem != null && dCtx.mounted) {
                          ScaffoldMessenger.of(dCtx)
                              .showSnackBar(SnackBar(content: Text(problem)));
                        }
                        return;
                      }
                      final f = outcome.single;
                      String text;
                      if (f.bytes != null && f.bytes!.isNotEmpty) {
                        text = String.fromCharCodes(f.bytes!);
                      } else if (f.path != null) {
                        text = await File(f.path!).readAsString();
                      } else {
                        return;
                      }
                      setLocal(() {
                        pickedBody = text;
                        pickedName = f.name;
                      });
                    },
                    child: Text(getLocalText.s("Choose…")),
                  ),
                ],
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(dCtx),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setLocal(() => busy = true);
                    UiMsg? err;
                    if (fileMode) {
                      if (pickedBody == null) {
                        // file-режим без нового файла: если и было file — просто
                        // переоткрыть текущий кэш нельзя, требуем выбор.
                        setLocal(() => busy = false);
                        ScaffoldMessenger.of(dCtx).showSnackBar(
                          SnackBar(content: Text(getLocalText.s("Choose a file first"))),
                        );
                        return;
                      }
                      // file: контроллер сам сгенерит свежий file:<uuid>.
                      err = await subController.updateSourceAt(
                        index,
                        fileBody: pickedBody,
                      );
                    } else {
                      final url = urlCtl.text.trim();
                      if (!isSubscriptionUrl(url)) {
                        setLocal(() => busy = false);
                        ScaffoldMessenger.of(dCtx).showSnackBar(
                          SnackBar(content: Text(getLocalText.s("Enter a valid http(s):// URL"))),
                        );
                        return;
                      }
                      err = await subController.updateSourceAt(index,
                          httpUrl: url);
                    }
                    if (!dCtx.mounted) return;
                    if (err == null) {
                      Navigator.pop(dCtx);
                    } else {
                      setLocal(() => busy = false);
                      ScaffoldMessenger.of(dCtx).showSnackBar(
                          SnackBar(content: Text(err.render())));
                    }
                  },
            child: busy
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(getLocalText.s("Save")),
          ),
        ],
      ),
    ),
  );
  urlCtl.dispose();
}
