import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/error_format.dart';
import '../../services/l10n/locale_controller.dart';
import '../../services/profile_dump_writer.dart';
import '../../services/ui_helpers.dart';
import '../../vpn/box_vpn_client.dart';
import '../../vpn/pprof_profile.dart';
import '../../widgets/safe_bottom.dart';

/// §207 — вкладка «Profiling» на экране Debug: pprof-слепки живого ядра
/// (goroutines / CPU / heap / allocs) через libbox PProfServer.
///
/// Жила в App Settings → Diagnostics, переехала сюда: это инструмент
/// диагностики, а не настройка — рядом с логами и крашами ему место, а
/// в списке тумблеров он был чужеродным.
///
/// Гейт — активный туннель: без работающего ядра снимать нечего.
class ProfilingTab extends StatefulWidget {
  const ProfilingTab({super.key});

  @override
  State<ProfilingTab> createState() => _ProfilingTabState();
}

class _ProfilingTabState extends State<ProfilingTab>
    with SnackHelper, AutomaticKeepAliveClientMixin {
  final _vpn = BoxVpnClient();

  /// Один PProfServer на порт — параллельные захваты дизейблим.
  bool _capturing = false;

  @override
  bool get wantKeepAlive => true;

  /// `[p]` несёт path+query, имя файла, text/binary и blocking-секунды.
  Future<void> _capture(PprofProfile p) async {
    if (_capturing) return;
    if (!(await _vpn.getVpnStatus()).isUp) {
      showSnack(getLocalText.s("VPN must be running to capture a profile."));
      return;
    }
    setState(() => _capturing = true);
    if (p.blockingSeconds > 0) {
      showSnack(getLocalText.s("Profiling for %ds…", p.blockingSeconds));
    }
    try {
      final bytes =
          await _vpn.pprofRaw(p.pathAndQuery, blockingSeconds: p.blockingSeconds);
      if (bytes.isEmpty) {
        showSnack(getLocalText.s("Profile was empty (timeout?)."));
        return;
      }
      final path = await ProfileDumpWriter.writeProfile(p, bytes);
      final name = path.split('/').last;
      // ignore: deprecated_member_use
      await Share.shareXFiles(
        [
          XFile(path,
              name: name,
              mimeType: p.isText ? 'text/plain' : 'application/octet-stream')
        ],
        text: p.isText
            ? 'L×Box ${p.label}'
            : 'L×Box ${p.label} — analyze with: go tool pprof $name',
        subject: name,
      );
    } catch (e) {
      showSnack(
          getLocalText.s("Capture failed: %s", formatUserError(e).render()));
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  static IconData _iconFor(String id) => switch (id) {
        'goroutine' => Icons.account_tree_outlined,
        'profile' => Icons.speed_outlined,
        'heap' => Icons.memory_outlined,
        'allocs' => Icons.dataset_outlined,
        _ => Icons.download_outlined,
      };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16).withSafeBottom(context),
      children: [
        Text(
          getLocalText.s("Capture a diagnostic snapshot of the running core and share it. Requires the VPN to be connected."),
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        for (final p in PprofProfile.all) ...[
          OutlinedButton.icon(
            onPressed: _capturing ? null : () => _capture(p),
            icon: (_capturing && p.blockingSeconds > 0)
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(_iconFor(p.id), size: 18),
            label: Text(getLocalText.s("Capture %s", p.label)),
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 4),
        Text(
          getLocalText.s("Binary profiles (.pb): go tool pprof file.pb\nHeap inuse_space: go tool pprof -inuse_space heap-*.pb"),
          style: TextStyle(
            fontSize: 11,
            fontFamily: 'monospace',
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
