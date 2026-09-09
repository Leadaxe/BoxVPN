import 'package:flutter/material.dart';

import '../models/ui_msg.dart';
import '../services/l10n/locale_controller.dart';
import 'app_bottom_sheet.dart';

/// §374 — что юзер выбрал в шите экспорта.
enum ExportAction {
  /// Системный диалог «Сохранить как» (SAF ACTION_CREATE_DOCUMENT).
  saveToFile,

  /// Публичная папка Downloads через MediaStore (API 29+).
  saveToDownloads,

  /// Системный share-sheet — отправить бэкап в другое приложение.
  share,
}

/// §374 — выбор способа экспорта.
///
/// Раньше кнопка Export вела сразу в share-sheet, и на устройствах без
/// файлового менеджера сохранить бэкап было некуда. Теперь способ юзер
/// выбирает явно, а недоступные пункты не показываются.
///
/// [canSaveToFile] — есть ли настоящий файловый менеджер (§372).
/// [canSaveToDownloads] — доступна ли MediaStore-запись (API 29+).
/// Когда оба false, над share показывается пояснение, почему сохранения нет.
///
/// Возвращает null, если юзер закрыл шит.
Future<ExportAction?> showExportActionSheet(
  BuildContext context, {
  required bool canSaveToFile,
  required bool canSaveToDownloads,
}) {
  return showAppBottomSheet<ExportAction>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canSaveToFile)
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: Text(getLocalText.s("Save to file")),
              subtitle: Text(getLocalText.s("Pick a folder on this device")),
              onTap: () => Navigator.pop(ctx, ExportAction.saveToFile),
            ),
          if (canSaveToDownloads)
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: Text(getLocalText.s("Save to Downloads")),
              subtitle: Text(getLocalText.s("Straight to the Downloads folder")),
              onTap: () => Navigator.pop(ctx, ExportAction.saveToDownloads),
            ),
          // Сохранять некуда — объясняем почему, чтобы share не выглядел
          // произвольным ограничением. Ключ общий с импортом (§372/§285).
          if (!canSaveToFile && !canSaveToDownloads)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                const ErrMsg(ErrKey.noFileManager).render(),
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ),
          ListTile(
            leading: const Icon(Icons.ios_share),
            title: Text(getLocalText.s("Share")),
            subtitle: Text(getLocalText.s("Send to another app")),
            onTap: () => Navigator.pop(ctx, ExportAction.share),
          ),
        ],
      ),
    ),
  );
}
