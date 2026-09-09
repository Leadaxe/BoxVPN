import 'dart:convert';

import 'package:flutter/material.dart';

import '../../services/error_format.dart';
import '../../services/l10n/locale_controller.dart';
import '../../widgets/app_bottom_sheet.dart';

/// Bottom-sheet editor for an inline user DNS rule (`kind: inline`).
///
/// `existing` — текущий entry при edit (null при add). `onSave` получает уже
/// собранный `entry` map (caller решает insert vs replace). `context` —
/// screen context (для `ScaffoldMessenger` снаружи sheet'а).
void showUserRuleEditor(
  BuildContext context, {
  required bool isNew,
  required Map<String, dynamic>? existing,
  required void Function(Map<String, dynamic> entry) onSave,
}) {
  final nameCtrl = TextEditingController(
    text: existing?['name']?.toString() ?? '',
  );
  final body = existing?['rule'];
  final bodyCtrl = TextEditingController(
    text: body is Map<String, dynamic>
        ? const JsonEncoder.withIndent('  ').convert(body)
        : '{\n  "rule_set": "geoip-ru",\n  "server": "yandex_doh"\n}',
  );

  showAppBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(isNew ? getLocalText.s("Add DNS Rule") : getLocalText.s("Edit DNS Rule"),
              style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: nameCtrl,
            decoration: InputDecoration(
              labelText: getLocalText.s("Name"),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 180,
            child: TextField(
              controller: bodyCtrl,
              maxLines: null,
              expands: true,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: InputDecoration(
                labelText: getLocalText.s("Rule body (JSON)"),
                border: const OutlineInputBorder(),
                isDense: true,
                alignLabelWithHint: true,
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            // l10n-exempt: JSON shape example (literal braces)
            'sing-box DNS rule shape: {rule_set, domain, domain_suffix, server, ...}',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(getLocalText.s("Name is required"))));
                return;
              }
              Map<String, dynamic>? parsed;
              try {
                final obj = jsonDecode(bodyCtrl.text);
                if (obj is! Map<String, dynamic>) {
                  throw const FormatException('Rule body must be a JSON object');
                }
                parsed = obj;
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(getLocalText.s(
                        "Invalid JSON: %s", formatUserError(e).render()))));
                return;
              }
              Navigator.pop(ctx);
              final entry = <String, dynamic>{
                'enabled': existing?['enabled'] ?? true,
                'kind': 'inline',
                'name': name,
                'rule': parsed,
              };
              onSave(entry);
            },
            child: Text(getLocalText.s("Save")),
          ),
        ],
      ),
    ),
  ).then((_) {
    nameCtrl.dispose();
    bodyCtrl.dispose();
  });
}
