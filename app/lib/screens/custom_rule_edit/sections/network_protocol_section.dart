import 'package:flutter/material.dart';

import '../../../models/custom_rule.dart'
    show kKnownNetworks, kKnownProtocols;
import '../../../services/l10n/locale_controller.dart';
import '../../../widgets/app_bottom_sheet.dart';

/// §240 — NETWORK & PROTOCOL section.
///
/// Collapsed view for the rule form: a header plus up to two rows of selected
/// chips — `Network` (L4 transport: tcp/udp/icmp) and `Protocol` (L7 sniff) —
/// and an `Edit` button opening a bottom-sheet picker. Empty → placeholder.
///
/// Both axes are routing-rule level (headless rule expresses neither), AND with
/// the rest of the rule; OR within each list. Between Network and Protocol —
/// AND (a packet must be on a selected transport AND match a selected L7).
class NetworkProtocolSection extends StatelessWidget {
  const NetworkProtocolSection({
    super.key,
    required this.networks,
    required this.protocols,
    required this.onToggleNetwork,
    required this.onToggleProtocol,
    required this.onClearAll,
  });

  final Set<String> networks;
  final Set<String> protocols;
  final void Function(String network, bool checked) onToggleNetwork;
  final void Function(String protocol, bool checked) onToggleProtocol;
  final VoidCallback onClearAll;

  Future<void> _openSheet(BuildContext context) {
    return showAppBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => NetworkProtocolSheet(
        networks: networks,
        protocols: protocols,
        onToggleNetwork: onToggleNetwork,
        onToggleProtocol: onToggleProtocol,
        onClearAll: onClearAll,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final hasAny = networks.isNotEmpty || protocols.isNotEmpty;
    // Ordered subsets so chips render in a stable, catalog order.
    final netChips =
        kKnownNetworks.where(networks.contains).toList(growable: false);
    final protoChips =
        kKnownProtocols.where(protocols.contains).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      getLocalText.s("NETWORK & PROTOCOL"),
                      style: t.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: t.colorScheme.primary,
                      ),
                    ),
                    Text(
                      getLocalText.s("AND with match. Transport (L4) and L7 sniff."),
                      style: TextStyle(
                        fontSize: 12,
                        color: t.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.tune, size: 18),
                label: Text(getLocalText.s("Edit")),
                onPressed: () => _openSheet(context),
              ),
            ],
          ),
        ),
        if (!hasAny)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              getLocalText.s("Any — tap Edit to filter by network / L7 protocol"),
              style: TextStyle(
                fontSize: 13,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else ...[
          if (netChips.isNotEmpty)
            _ChipRow(label: 'Network', values: netChips),
          if (protoChips.isNotEmpty)
            _ChipRow(label: 'Protocol', values: protoChips),
        ],
      ],
    );
  }
}

/// One labelled row of read-only chips in the collapsed view.
class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.label, required this.values});

  final String label;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: t.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: values
                  .map((v) => Chip(
                        label: Text(v),
                        labelStyle: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

/// §240 — bottom-sheet picker with two chip sections: Network (L4) and
/// Protocol (L7). Selection is live (each tap toggles the underlying set via
/// the callbacks); Done just closes the sheet.
class NetworkProtocolSheet extends StatefulWidget {
  const NetworkProtocolSheet({
    super.key,
    required this.networks,
    required this.protocols,
    required this.onToggleNetwork,
    required this.onToggleProtocol,
    required this.onClearAll,
  });

  final Set<String> networks;
  final Set<String> protocols;
  final void Function(String network, bool checked) onToggleNetwork;
  final void Function(String protocol, bool checked) onToggleProtocol;
  final VoidCallback onClearAll;

  @override
  State<NetworkProtocolSheet> createState() => _NetworkProtocolSheetState();
}

class _NetworkProtocolSheetState extends State<NetworkProtocolSheet> {
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final anySelected =
        widget.networks.isNotEmpty || widget.protocols.isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(getLocalText.s("Protocol filter"),
                style: t.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              getLocalText.s("Matches when traffic is on a selected network AND matches a selected L7 protocol."),
              style: TextStyle(
                fontSize: 12,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SheetSectionTitle(
                      title: 'Network',
                      subtitle: 'Transport (L4)',
                    ),
                    _ChipPicker(
                      values: kKnownNetworks,
                      selected: widget.networks,
                      onToggle: (v, checked) {
                        widget.onToggleNetwork(v, checked);
                        setState(() {});
                      },
                    ),
                    const SizedBox(height: 12),
                    _SheetSectionTitle(
                      title: 'Protocol',
                      subtitle: 'L7 sniff signature',
                    ),
                    _ChipPicker(
                      values: kKnownProtocols,
                      selected: widget.protocols,
                      onToggle: (v, checked) {
                        widget.onToggleProtocol(v, checked);
                        setState(() {});
                      },
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 24),
            Row(
              children: [
                TextButton(
                  onPressed: anySelected
                      ? () {
                          widget.onClearAll();
                          setState(() {});
                        }
                      : null,
                  child: Text(getLocalText.s("Clear all")),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(getLocalText.s("Done")),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetSectionTitle extends StatelessWidget {
  const _SheetSectionTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            title,
            style: t.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: t.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 12,
              color: t.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// A wrap of selectable [FilterChip]s over [values].
class _ChipPicker extends StatelessWidget {
  const _ChipPicker({
    required this.values,
    required this.selected,
    required this.onToggle,
  });

  final List<String> values;
  final Set<String> selected;
  final void Function(String value, bool checked) onToggle;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: values.map((v) {
        final checked = selected.contains(v);
        return FilterChip(
          label: Text(
            v,
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          ),
          selected: checked,
          onSelected: (val) => onToggle(v, val),
        );
      }).toList(),
    );
  }
}
