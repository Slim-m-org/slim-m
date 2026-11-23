// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call stats pane while its numbers load: the window picker and quiet placeholders where the cards will be.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../settings/widgets/settings_section_header.dart';

class CallStatsGhost extends StatelessWidget {
  const CallStatsGhost({super.key, required this.selector});

  final Widget selector;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading your call stats',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Talk time',
          description: 'Only you can see these.',
          children: [
            selector,
            const ExcludeSemantics(
              child: Column(children: [_Row(), _Row(), _Row()]),
            ),
          ],
        ),
      ],
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s16,
        vertical: 18,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final width in const [140.0, 60.0])
            Container(
              width: width,
              height: 12,
              decoration: BoxDecoration(
                color: tokens.stripe,
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
            ),
        ],
      ),
    );
  }
}
