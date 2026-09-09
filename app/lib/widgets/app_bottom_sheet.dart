import 'package:flutter/material.dart';

/// §429 — единственная точка показа модальных шторок.
///
/// Android рисует edge-to-edge: системная панель навигации (жесты или три
/// кнопки) ложится ПОВЕРХ нижнего края окна. `showModalBottomSheet` сам этот
/// отступ не добавляет (`useSafeArea` закрывает только верх и бока), и всё, что
/// шторка кладёт последним — кнопка «Save», строка действий — уезжает под
/// панель. Раньше каждая шторка решала это по-своему (SafeArea / viewInsets /
/// ничего), и половина решала неверно.
///
/// Здесь оборачиваем контент шторки единообразно:
///  1. `Padding(bottom: viewInsets.bottom)` — поднять над клавиатурой;
///  2. `SafeArea(top: false)` — отступ под системную панель навигации.
///
/// Порядок важен: при открытой клавиатуре `MediaQuery.padding.bottom` уже
/// равен нулю (панель скрыта клавиатурой), поэтому двойного зазора нет.
/// `SafeArea` потребляет padding, так что внутренний `MediaQuery.paddingOf`
/// в контенте видит ноль — дублировать отступ внутри шторки не нужно.
///
/// Контент с `DraggableScrollableSheet` тоже совместим: обёртки лишь уменьшают
/// доступную высоту на величину отступов.
///
/// Прямой вызов `showModalBottomSheet` вне этого файла запрещён —
/// `test/contract/bottom_sheet_helper_test.dart`.
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  bool useSafeArea = false,
  Color? backgroundColor,
  ShapeBorder? shape,
  Clip? clipBehavior,
  BoxConstraints? constraints,

  /// Поднимать контент над клавиатурой. Выключать только если контент сам
  /// управляет высотой относительно клавиатуры.
  bool keyboardInset = true,

  /// Отступ под системную панель навигации.
  bool safeBottom = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useRootNavigator: useRootNavigator,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: showDragHandle,
    useSafeArea: useSafeArea,
    backgroundColor: backgroundColor,
    shape: shape,
    clipBehavior: clipBehavior,
    constraints: constraints,
    builder: (ctx) {
      Widget child = builder(ctx);
      if (safeBottom) child = SafeArea(top: false, child: child);
      if (keyboardInset) {
        // Контент видит viewInsets.bottom == 0: подъём над клавиатурой уже
        // сделан здесь, а старые «свои» Padding(viewInsets) внутри шторок
        // иначе давали бы двойной зазор.
        child = Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: MediaQuery.removeViewInsets(
            context: ctx,
            removeBottom: true,
            child: child,
          ),
        );
      }
      return child;
    },
  );
}
