import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/warp_wizard_screen.dart';

void main() {
  const mark = '(recommended)';

  test('§424 label = чистое значение, пометка только в labelWidget', () {
    final e = warpPresetEntry('a.example', 'a.example', mark);
    expect(e.label, 'a.example');
    expect(e.labelWidget, isA<Text>());
    expect((e.labelWidget as Text).data, 'a.example $mark');

    final plain = warpPresetEntry('b.example', 'a.example', mark);
    expect(plain.label, 'b.example');
    expect(plain.labelWidget, isNull);

    // Пустой recommended → пометок нет ни у кого.
    expect(warpPresetEntry('', '', mark).labelWidget, isNull);
  });

  testWidgets('§424 выбор recommended-пункта кладёт в контроллер чистое значение',
      (tester) async {
    final c = TextEditingController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DropdownMenu<String>(
          controller: c,
          requestFocusOnTap: true,
          dropdownMenuEntries: [
            warpPresetEntry('consumer-masque.cloudflareclient.com',
                'consumer-masque.cloudflareclient.com', mark),
            warpPresetEntry('www.cloudflare.com',
                'consumer-masque.cloudflareclient.com', mark),
          ],
        ),
      ),
    ));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    // В меню пометка видна (DropdownMenu держит вторую, невидимую копию
    // пунктов для замера ширины — потому findsWidgets, не findsOneWidget).
    expect(find.text('consumer-masque.cloudflareclient.com $mark'),
        findsWidgets);
    await tester
        .tap(find.text('consumer-masque.cloudflareclient.com $mark').last);
    await tester.pumpAndSettle();
    expect(c.text, 'consumer-masque.cloudflareclient.com');
  });
}
