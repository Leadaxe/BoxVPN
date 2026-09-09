import 'package:flutter/material.dart';

/// §429 — нижний отступ под системную панель навигации.
///
/// Android рисует edge-to-edge: панель навигации ложится поверх нижнего края
/// окна. Скроллер добавляет этот отступ сам ТОЛЬКО когда `padding` не задан;
/// любой явный `padding:` его выключает, и последний элемент списка (кнопка
/// Save, хвост лога) уезжает под панель. Правило проекта: у вертикального
/// скроллера с явным `padding:` — всегда `.withSafeBottom(context)`
/// (`test/contract/bottom_inset_contract_test.dart`).
///
/// Добавлять безопасно везде: если выше по дереву уже стоит `SafeArea`
/// (шторка через `showAppBottomSheet`, footer с `SafeArea(top: false)`), он
/// потребил padding и здесь прибавится ноль — двойного зазора не бывает.
extension SafeBottomInset on EdgeInsets {
  EdgeInsets withSafeBottom(BuildContext context) =>
      copyWith(bottom: bottom + MediaQuery.paddingOf(context).bottom);
}

/// То же для `EdgeInsetsGeometry` (поле виджета, directional-отступы).
/// Для литерала `EdgeInsets` Dart выберет более точное расширение выше.
extension SafeBottomInsetGeometry on EdgeInsetsGeometry {
  EdgeInsetsGeometry withSafeBottom(BuildContext context) =>
      add(EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom));
}
