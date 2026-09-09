// §375 — экран сканирования QR-кода.
//
// Источник строки для импорта: код с камеры уходит в тот же `addFromInput`,
// что paste/file. Экран ничего не добавляет сам — только возвращает исход,
// разбор формата и подтверждение остаются на вызывающем (subscriptions_screen).
//
// Контракт исходов зеркалит `PickOutcome` из services/file_import.dart:
// отмена — не ошибка (молчим), остальное — снекбар вызывающего.
//
// §382 — декодер `flutter_zxing` (ZXing-C++ через FFI) вместо ML Kit:
// сборка F-Droid не принимает проприетарные блобы и требует побитовой
// воспроизводимости. Контракт исходов при замене не менялся; камерой и
// фонариком владеет сам `ReaderWidget`, своего контроллера у экрана нет.

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import '../services/app_log.dart';
import '../services/error_format.dart';
import '../services/l10n/locale_controller.dart';

/// Результат работы экрана сканера.
sealed class ScanOutcome {
  const ScanOutcome();
}

/// Код распознан. [value] — сырое содержимое, не разобранное и не
/// провалидированное: разбор делает вызывающий тем же путём, что для буфера.
class ScannedCode extends ScanOutcome {
  const ScannedCode(this.value);

  final String value;
}

/// Юзер ушёл с экрана, не отсканировав. Не ошибка — вызывающий выходит молча.
class ScanCancelled extends ScanOutcome {
  const ScanCancelled();
}

/// Отказано в доступе к камере.
class ScanDenied extends ScanOutcome {
  const ScanDenied();
}

/// Прочий сбой камеры/детектора. [error] — исходное исключение для логов.
class ScanFailed extends ScanOutcome {
  const ScanFailed(this.error);

  final Object error;
}

/// Текст для не-успешного исхода — снекбаром у вызывающего, либо null для
/// [ScannedCode] и [ScanCancelled] (юзер сам ушёл — молчим).
///
/// Зеркало `pickProblemText` из file_import.dart.
String? scanProblemText(ScanOutcome outcome) => switch (outcome) {
  ScannedCode() || ScanCancelled() => null,
  ScanDenied() => getLocalText.s("Camera access denied"),
  ScanFailed(:final error) => getLocalText.s(
    "Camera error: %s",
    formatUserError(error).render(),
  ),
};

/// Полноэкранный сканер. Возвращает [ScanOutcome] через `Navigator.pop`.
///
/// Вызов: `final outcome = await Navigator.push<ScanOutcome>(...)`. При уходе
/// системной кнопкой «назад» pop произойдёт без значения — вызывающий трактует
/// null как [ScanCancelled].
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

/// Коды `CameraException` от плагина `camera` при отказе в доступе. Ошибка
/// приезжает строкой, а не enum, — сверяем по известным кодам. На Android
/// приходит только `CameraAccessDenied`, остальные два iOS-only. Неизвестный
/// код трактуем как [ScanFailed]: лучше показать текст ошибки, чем соврать
/// про разрешения.
bool _isPermissionDenied(String code) =>
    code == 'CameraAccessDenied' ||
    code == 'CameraAccessDeniedWithoutPrompt' ||
    code == 'CameraAccessRestricted';

class _QrScanScreenState extends State<QrScanScreen> {
  /// Детектор отдаёт кадры пачками — один и тот же код придёт несколько раз
  /// подряд. Без флага получаем повторные pop'ы уже закрытого экрана.
  bool _handled = false;

  void _finish(ScanOutcome outcome) {
    if (_handled || !mounted) return;
    _handled = true;
    Navigator.of(context).pop(outcome);
  }

  /// Счётчик неудачных попыток — только чтобы моргнуть индикатором. Без него
  /// экран выглядит мёртвым: кнопки съёмки нет, попытки идут сами, и юзеру
  /// неоткуда узнать, смотрит сканер или завис.
  int _attempts = 0;

  void _onScan(Code code) {
    if (_handled) return;
    final value = code.text?.trim();
    if (value == null || value.isEmpty) return;
    AppLog.I.info('[qr] scanned ${value.length} chars');
    _finish(ScannedCode(value));
  }

  void _onScanFailure(Code code) {
    if (_handled || !mounted) return;
    setState(() => _attempts++);
  }

  /// Камера не поднялась. `ReaderWidget` отдаёт исход инициализации сюда:
  /// `error == null` — контроллер жив, иначе экран закрываем.
  void _onControllerCreated(CameraController? controller, Exception? error) {
    if (error == null || _handled) return;
    final code = error is CameraException ? error.code : null;
    AppLog.I.warning('[qr] scanner error: ${code ?? error}');
    _finish(
      code != null && _isPermissionDenied(code)
          ? const ScanDenied()
          : ScanFailed(error),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(getLocalText.s("Scan QR code"))),
      body: Stack(
        fit: StackFit.expand,
        children: [
          ReaderWidget(
            onScan: _onScan,
            onScanFailure: _onScanFailure,
            onControllerCreated: _onControllerCreated,
            // Сужаем до QR: не ловим случайные EAN/штрихкоды с окружающих
            // предметов.
            codeFormat: Format.qrCode,
            // Из встроенных кнопок оставляем только фонарик: галерея — нецель
            // §375 (распознавание из файла), вторая камера для сканирования
            // кода с экрана бесполезна.
            showGallery: false,
            showToggleCamera: false,
            // Область поиска. Виджет отдаёт декодеру ровно тот квадрат, что
            // рисует рамкой: `min(w,h) * cropPercent`. Дефолт 0.5 — это лишь
            // четверть площади кадра, из-за чего код приходится ловить в
            // маленькое окно. 0.9 берёт почти весь кадр по короткой стороне.
            cropPercent: 0.9,
            // ZXing-C++ без tryHarder делает один быстрый проход и сдаётся на
            // неидеальном кадре (блик, наклон, расфокус). Здесь мы сканируем
            // одиночный код по требованию юзера, а не потоково в фоне, —
            // тщательный поиск важнее экономии батареи.
            tryHarder: true,
            // Крупный код с близкого расстояния декодер иначе не берёт:
            // downscale даёт ему второй масштаб для поиска.
            tryDownscale: true,
            // Инверсию не ищем: инвертированные QR практически не встречаются,
            // а лишний проход по каждому кадру заметен.
            tryInverted: false,
            // Пауза ПОСЛЕ неудачной попытки (не между кадрами): пока она идёт,
            // кадры с камеры выбрасываются. Дефолт 1000 мс = одна попытка в
            // секунду, и юзер не понимает, в какой момент сканер вообще
            // смотрит. 300 мс + время самого прохода (с tryHarder он не
            // мгновенный) ⇒ порядка двух-трёх попыток в секунду.
            scanDelay: const Duration(milliseconds: 300),
            // После успеха экран и так закрывается по _handled; держим паузу
            // короткой, чтобы не залипал кадр перед закрытием.
            scanDelaySuccess: const Duration(milliseconds: 300),
          ),
          // Подсказка поверх превью — юзер видит, что от него хотят.
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: Container(
                width: double.infinity,
                color: Colors.black54,
                padding: const EdgeInsets.symmetric(
                  vertical: 16,
                  horizontal: 24,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Моргает на каждой попытке декодирования: видно, что сканер
                    // работает, даже пока код не пойман.
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 10),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _attempts.isEven ? Colors.white : Colors.white24,
                      ),
                    ),
                    Flexible(
                      child: Text(
                        getLocalText.s("Point the camera at a QR code"),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
