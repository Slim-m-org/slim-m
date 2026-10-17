// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Access to approve": the host capabilities a module asks for, each with a
/// switch, so the admin decides what a module may do before it runs
/// (docs/decisions/0023-mediated-host-capabilities.md).
///
/// A capability the module declares but this client cannot describe is not
/// offered here: the host implements only the ones named below, so a switch for
/// anything else would approve nothing.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;

import '../../widgets/settings_info_line.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_toggle_row.dart';

/// One grantable capability: its switch copy and the consent sentence. The
/// sentence takes the manifest's details for it (a host list), so a capability
/// that names targets states them.
typedef DockCapability = ({
  String label,
  String description,
  String Function(List<String> details) warning,
});

/// The host capabilities the server can grant, in the order they are listed.
/// Adding one is one entry here.
final dockHostCapabilities = <String, DockCapability>{
  'kv.store': (
    label: 'Remember data',
    description: 'A small private store for this module.',
    warning: (_) => 'Can keep its own private data on your server.',
  ),
  'message.post': (
    label: 'Post messages',
    description: 'Posts as whoever runs it, marked "via" this module.',
    warning: (_) =>
        'Can post messages in your space as whoever runs it, marked as '
        'this module.',
  ),
  'net.fetch': (
    label: 'Reach the internet',
    description: 'Sends requests to the sites it names.',
    warning: _networkWarning,
  ),
  'schedule': (
    label: 'Run on its own',
    description: 'Runs on a timer and posts as itself.',
    warning: (_) =>
        'Can run on a timer with nobody asking, and post as itself in a '
        'channel you choose.',
  ),
};

/// The second, separate yes for `net.fetch` to reach private addresses.
const dockLocalNetworkLabel = 'Local network';
const dockLocalNetworkWarning =
    'Can also reach devices on your home network, like a NAS or media server.';

String _networkWarning(List<String> hosts) {
  final names = switch (hosts.length) {
    0 => 'the sites it names',
    1 => hosts.single,
    _ => '${hosts.take(hosts.length - 1).join(', ')} and ${hosts.last}',
  };
  return 'Can send data from your server to $names.';
}

/// What [capability]'s sentence names for [manifest]: the hosts of `net.fetch`.
List<String> dockCapabilityDetails(
  api.DockManifest manifest,
  String capability,
) => capability == 'net.fetch' ? manifest.network?.hosts ?? const [] : const [];

/// The consent sentence for [capability], or null when this client has none.
String? dockCapabilityWarning(
  String capability, {
  List<String> details = const [],
}) => dockHostCapabilities[capability]?.warning(details);

/// The capabilities among [declared] the host can grant, in listed order.
List<String> grantableHostCapabilities(Iterable<String> declared) => [
  for (final capability in dockHostCapabilities.keys)
    if (declared.contains(capability)) capability,
];

class DockHostAccessCard extends StatelessWidget {
  const DockHostAccessCard({
    super.key,
    required this.manifest,
    required this.approved,
    required this.onChanged,
    required this.moduleName,
    this.localNetworkApproved = false,
    this.onLocalNetworkChanged,
    this.reapprove = const [],
    this.enabled = true,
  });

  final api.DockManifest manifest;
  final Set<String> approved;
  final void Function(String capability, bool approved) onChanged;
  final String moduleName;

  /// Whether the second, local network yes is on.
  final bool localNetworkApproved;
  final ValueChanged<bool>? onLocalNetworkChanged;

  /// Capabilities a new build needs approved again.
  final List<String> reapprove;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final grantable = grantableHostCapabilities(manifest.capabilities);
    if (grantable.isEmpty) return const SizedBox.shrink();
    final access = SettingsSectionCard(
      title: 'Access to approve',
      children: [
        SettingsInfoLine(
          reapprove.isEmpty
              ? 'Off unless you turn it on.'
              : 'A new build needs ${_labels(reapprove)} approved again.',
        ),
        for (final capability in grantable)
          SettingsToggleRow(
            label: dockHostCapabilities[capability]!.label,
            description: _description(capability),
            value: approved.contains(capability),
            onChanged: enabled ? (v) => onChanged(capability, v) : null,
            semanticLabel:
                '${dockHostCapabilities[capability]!.label} for $moduleName',
          ),
      ],
    );
    if (!showsLocalNetwork) return access;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        access,
        SettingsSectionCard(
          title: 'Second approval',
          children: [
            SettingsToggleRow(
              label: dockLocalNetworkLabel,
              description: dockLocalNetworkWarning,
              value: localNetworkApproved,
              onChanged: enabled ? onLocalNetworkChanged : null,
              semanticLabel: '$dockLocalNetworkLabel for $moduleName',
            ),
          ],
        ),
      ],
    );
  }

  /// The local switch exists only while its parent switch is on.
  bool get showsLocalNetwork =>
      (manifest.network?.local ?? false) && approved.contains('net.fetch');

  String _description(String capability) {
    final details = dockCapabilityDetails(manifest, capability);
    final entry = dockHostCapabilities[capability]!;
    return details.isEmpty ? entry.description : entry.warning(details);
  }

  static String _labels(List<String> capabilities) => capabilities
      .map((c) => dockHostCapabilities[c]?.label ?? c)
      .join(' and ');
}
