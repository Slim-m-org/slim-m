// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The danger-bordered card that holds one irreversible action.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_detail_row.dart';
import 'settings_section_header.dart';

/// A [title] header over a card edged in the danger colour: [message] says
/// what the [action] does, and [error] sits under it until dismissed.
class SettingsDangerCard extends StatelessWidget {
  const SettingsDangerCard({
    super.key,
    required this.title,
    required this.message,
    required this.action,
    this.error,
  });

  final String title;
  final String message;
  final Widget action;
  final Widget? error;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHeader(title),
        DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            border: Border.all(color: tokens.dangerText.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(AppRadii.card),
          ),
          child: AppCardRowScope(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SettingsActionRow(message: message, action: action),
                if (error case final error?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.s16,
                      0,
                      AppSpacing.s16,
                      AppSpacing.s16,
                    ),
                    child: error,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
