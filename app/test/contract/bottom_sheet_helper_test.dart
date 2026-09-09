import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// §429 — все модальные шторки идут через `showAppBottomSheet`
// (lib/widgets/app_bottom_sheet.dart): он один добавляет отступ под системную
// панель навигации и клавиатуру. Прямой `showModalBottomSheet` в коде экрана
// снова уронит кнопку под панель — ровно то, с чем пришли с 4PDA.
void main() {
  test('showModalBottomSheet is called only from the helper', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path.endsWith('widgets/app_bottom_sheet.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('showModalBottomSheet')) {
          offenders.add('${f.path}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'use showAppBottomSheet (lib/widgets/app_bottom_sheet.dart)');
  });
}
