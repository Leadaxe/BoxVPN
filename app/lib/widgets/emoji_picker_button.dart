import 'package:flutter/material.dart';

import '../services/node_emoji.dart';
import '../services/l10n/locale_controller.dart';
import 'app_bottom_sheet.dart';

/// §090 G2b — кнопка-пикер эмодзи. Открывает bottom-sheet с палитрой
/// [kEmojiPalette]; тап по эмодзи зовёт [onPick]. Caller сам вставляет
/// эмодзи в нужное поле (тег). Переиспользуется в node_settings и форме
/// создания сервера.
class EmojiPickerButton extends StatelessWidget {
  const EmojiPickerButton({super.key, required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.add_reaction_outlined),
      tooltip: getLocalText.s("Insert emoji"),
      onPressed: () async {
        final picked = await showAppBottomSheet<String>(
          context: context,
          showDragHandle: true,
          builder: (ctx) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  for (final e in kEmojiPalette)
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => Navigator.pop(ctx, e),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(e, style: const TextStyle(fontSize: 30)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        if (picked != null) onPick(picked);
      },
    );
  }
}
