// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the conversation pane shows for a channel id the local store cannot
/// resolve once the first sync has finished.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/routes.dart';

/// Hidden and missing channels read the same on purpose: the server does not
/// say which, and the pane must not offer a composer for either.
class ChannelNotFound extends StatelessWidget {
  const ChannelNotFound({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s16),
        child: AppErrorState(
          message:
              'This channel was not found, or you do not have access to it.',
          dismissLabel: 'Back to channels',
          onDismiss: () => context.go(Routes.channels),
        ),
      ),
    ),
  );
}
