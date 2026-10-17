// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "What it adds": a plain-language list of a module's extension points - the
/// slash commands, apps, and code-block runners it surfaces - shown on its Dock
/// page so an admin sees what installing actually does in chat, and a module
/// author can confirm their manifest registered what they meant.
///
/// This reads whatever the manifest declares, naming nothing module-specific
/// (docs/decisions/0021). A kind it does not recognise still lists generically
/// rather than vanishing, so a future extension-point kind is visible here the
/// day it exists (docs/decisions/0022).
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_section_header.dart';

class DockWhatItAddsCard extends StatelessWidget {
  const DockWhatItAddsCard({super.key, required this.extensionPoints});

  final List<api.DockExtensionPoint> extensionPoints;

  @override
  Widget build(BuildContext context) {
    final entries = extensionPoints.map(_describe).nonNulls.toList();
    if (entries.isEmpty) {
      // A module of bare commands only surfaces nothing in chat; its commands run from the panel below when it is installed.
      return const SizedBox.shrink();
    }
    return SettingsSectionCard(
      title: 'What it adds',
      children: [
        for (final (title, subtitle) in entries)
          SettingsDetailRow(title: title, detail: subtitle),
      ],
    );
  }

  /// A human `(title, subtitle)` for one extension point, or null for a bare
  /// `command` (the plumbing the surfaced kinds invoke, not itself an entry
  /// point). An unrecognised kind still returns a generic entry.
  static (String, String)? _describe(api.DockExtensionPoint ep) {
    final described = ep.description;
    switch (ep.kind) {
      case 'command':
        return null;
      case 'slash-command':
        return (
          '/${ep.name}',
          described ?? 'A command you can type in the composer.',
        );
      case 'app':
        return (ep.name, described ?? 'An app you can launch into a channel.');
      case 'code-block-runner':
        // A runner that names no language is offered on nothing, so say so.
        if (ep.language == null) {
          return (
            'Run code blocks',
            described ??
                'This module has not said which language it runs, so no Run '
                    'button is offered until it does.',
          );
        }
        return (
          'Run ${ep.language} code blocks',
          described ?? 'Adds a Run button on matching code blocks.',
        );
      default:
        return (ep.name, described ?? ep.kind);
    }
  }
}
