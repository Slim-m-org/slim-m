// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A connector's page sections (decision 0090): what its token may do, in
/// place of a module's host access, and its token, shown once.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../permissions.dart';
import '../../widgets/bot_env_block.dart';
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_info_line.dart';
import '../../widgets/settings_secret_reveal.dart';
import '../../widgets/settings_section_header.dart';

/// What a connector's [bits] let its token do, administrator and viewing included.
List<String> dockConnectorLabels(int bits) => [
  for (final (bit, label) in Perm.editable)
    if (bits & bit != 0) label,
];

/// "Token access": the permissions asked for before install, approved after.
class DockConnectorCard extends StatelessWidget {
  const DockConnectorCard({
    super.key,
    required this.manifest,
    required this.installed,
    required this.busy,
    this.onNewToken,
  });

  final api.DockManifest manifest;
  final api.InstalledDockModule? installed;
  final bool busy;

  /// Replaces a lost token; offered once it is installed.
  final VoidCallback? onNewToken;

  @override
  Widget build(BuildContext context) {
    final bits =
        installed?.connectorPermissions ?? manifest.connectorPermissions ?? 0;
    final labels = dockConnectorLabels(bits);
    return SettingsSectionCard(
      title: 'Token access',
      children: [
        SettingsInfoLine(
          manifest.hostRun == null
              ? 'Runs outside your server, as a bot with its own token.'
              : 'Runs on this server in a sandbox, as a bot with its own token.',
        ),
        SettingsDetailRow(
          title: installed == null ? 'Asks to' : 'Can',
          detail: labels.isEmpty ? 'Nothing' : joinLabels(labels),
        ),
        if (installed != null && onNewToken != null)
          SettingsDetailRow(
            title: 'Token',
            detail: 'A new one stops the old one working.',
            stackTrailingWhenNarrow: true,
            trailing: AppButton(
              label: 'New token',
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.sm,
              disabled: busy,
              onPressed: onNewToken,
            ),
          ),
      ],
    );
  }
}

/// The connector's token, shown once with copy actions until dismissed.
class DockConnectorTokenReveal extends StatelessWidget {
  const DockConnectorTokenReveal({
    super.key,
    required this.name,
    required this.token,
    required this.serverUrl,
    required this.onDismiss,
  });

  final String name;
  final String token;
  final Uri serverUrl;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => SettingsSecretReveal(
    warning:
        'This is the only time $name\'s token is shown. Copy it now and give '
        'it to the connector. If you lose it, make a new one here.',
    value: token,
    valueSemanticsLabel: 'Connector token for $name',
    copyLabel: 'Copy token',
    extraCopyLabel: 'Copy env block',
    extraCopyValue: botEnvBlock(url: serverUrl, token: token),
    onDismiss: onDismiss,
  );
}
