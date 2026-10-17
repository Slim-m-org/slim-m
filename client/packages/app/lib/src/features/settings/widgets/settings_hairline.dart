// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The full-width rule between the rows of a settings card.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class SettingsHairline extends StatelessWidget {
  const SettingsHairline({super.key});

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: 1,
    color: Theme.of(context).extension<AppTokens>()!.borderSubtle,
  );
}

/// Rows that share one slot, with a [SettingsHairline] between each pair: the
/// card's own children, or several rows a section hands the card as one.
class SettingsRowGroup extends StatelessWidget {
  const SettingsRowGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SettingsHairline(),
        children[i],
      ],
    ],
  );
}
