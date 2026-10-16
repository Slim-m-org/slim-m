// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A quiet sentence inside a flush settings card, at the card's own inset.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_section_header.dart';

class SettingsCardNote extends StatelessWidget {
  const SettingsCardNote(this.text, {super.key, this.warn = false});

  final String text;

  /// The sentence is a caution (something will not happen until the admin acts).
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SettingsCardBlock(
      children: [
        Text(
          text,
          style: AppText.caption.copyWith(
            color: warn ? tokens.warnText : tokens.textSecondary,
          ),
        ),
      ],
    );
  }
}
