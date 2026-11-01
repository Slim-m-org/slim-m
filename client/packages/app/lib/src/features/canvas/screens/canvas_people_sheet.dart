// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The people list as a sheet, for a pane too narrow for the anchored popover.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'canvas_people_panel.dart';
import 'canvas_people_session.dart';

Future<void> showCanvasPeopleSheet(BuildContext context) {
  final session = CanvasPeopleScope.maybeOf(context);
  return showAppSheet<void>(
    context,
    scrolls: true,
    semanticLabel: 'People here',
    builder: (sheet) => CanvasPeopleScope(
      notifier: session,
      child: CanvasPeopleSheet(onDone: () => Navigator.of(sheet).pop()),
    ),
  );
}

class CanvasPeopleSheet extends StatelessWidget {
  const CanvasPeopleSheet({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              'People here',
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
          // The sheet is bounded (scrolls: true), so a long list scrolls under the pinned heading.
          Flexible(
            child: SingleChildScrollView(
              child: CanvasPeopleRows(onDone: onDone),
            ),
          ),
        ],
      ),
    );
  }
}
