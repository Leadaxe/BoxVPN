import 'dart:convert';

import 'package:flutter/material.dart';
import 'safe_bottom.dart';

/// §333 — построчный просмотр большого read-only текста.
///
/// `Text`/`SelectableText` кладут весь текст в один `Paragraph`: layout и
/// память O(N) по документу, фриз при открытии, на слабых устройствах —
/// смерть от lmkd. Здесь текст режется на строки-элементы `ListView.builder`
/// (layout только видимых). Сквозное «выделить всё пальцем» при виртуализации
/// невозможно — рядом с такими вьюерами всегда есть кнопка Copy; выделение
/// в пределах видимого работает через [SelectionArea] у [BigTextView].
///
/// Строки длиннее [kBigTextChunkChars] режутся на куски: undecoded
/// base64-тело подписки — это ОДНА строка на сотни КБ, без чанкования она
/// снова стала бы единым гигантским параграфом. Стык чанков при wrap
/// неотличим от обычного переноса строки.
const int kBigTextChunkChars = 4096;

List<String> chunkTextLines(String text, {int maxChunk = kBigTextChunkChars}) {
  final out = <String>[];
  for (final line in const LineSplitter().convert(text)) {
    if (line.length <= maxChunk) {
      out.add(line);
      continue;
    }
    for (var i = 0; i < line.length; i += maxChunk) {
      out.add(line.substring(
          i, i + maxChunk > line.length ? line.length : i + maxChunk));
    }
  }
  return out;
}

/// Standalone-вьюер: сам себе скролл (замена
/// `SingleChildScrollView(child: SelectableText(...))`).
class BigTextView extends StatefulWidget {
  const BigTextView({
    super.key,
    required this.text,
    this.style,
    this.padding = const EdgeInsets.all(12),
  });

  final String text;
  final TextStyle? style;
  final EdgeInsetsGeometry padding;

  @override
  State<BigTextView> createState() => _BigTextViewState();
}

class _BigTextViewState extends State<BigTextView> {
  late List<String> _chunks;

  @override
  void initState() {
    super.initState();
    _chunks = chunkTextLines(widget.text);
  }

  @override
  void didUpdateWidget(BigTextView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _chunks = chunkTextLines(widget.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: ListView.builder(
        padding: widget.padding.withSafeBottom(context),
        itemCount: _chunks.length,
        itemBuilder: (context, i) => Text(
          // Пустая строка схлопнулась бы в 0-высотный Text — визуально
          // пропадает пустая строка исходника.
          _chunks[i].isEmpty ? ' ' : _chunks[i],
          style: widget.style,
        ),
      ),
    );
  }
}

/// Sliver-вариант для встраивания в `CustomScrollView` после «шапки»
/// (замена `SelectableText` внутри `ListView(children: [...])`).
class BigTextSliver extends StatefulWidget {
  const BigTextSliver({super.key, required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  State<BigTextSliver> createState() => _BigTextSliverState();
}

class _BigTextSliverState extends State<BigTextSliver> {
  late List<String> _chunks;

  @override
  void initState() {
    super.initState();
    _chunks = chunkTextLines(widget.text);
  }

  @override
  void didUpdateWidget(BigTextSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _chunks = chunkTextLines(widget.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SliverList.builder(
      itemCount: _chunks.length,
      itemBuilder: (context, i) => Text(
        _chunks[i].isEmpty ? ' ' : _chunks[i],
        style: widget.style,
      ),
    );
  }
}
