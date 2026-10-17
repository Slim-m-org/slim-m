// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shows a refused moderation write above the whole app, wherever it started.
///
/// Mounted once by `appChromeBuilder`, because the write is started from
/// surfaces that close before it answers (a row menu, the profile popover, the
/// call screen) and the member pane that used to hold the failure is a closed
/// drawer on a phone. A persistent error state, not a toast: it stays until
/// dismissed or the next write starts.
///
/// A band above the app rather than an overlay on it, so it never covers the
/// header buttons or the composer it would otherwise float over. The child
/// keeps one slot in the column whether or not the band is showing, so the
/// routed app is never remounted when a failure appears.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/member_moderation_error.dart';

class ModerationErrorHost extends ConsumerWidget {
  const ModerationErrorHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = ref.watch(memberModerationErrorProvider);
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      children: [
        if (message == null)
          const SizedBox.shrink()
        else
          Material(
            color: tokens.surfaceBase,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.s8),
                child: AppErrorState(
                  key: const Key('moderation-error'),
                  message: message,
                  onDismiss: () =>
                      ref.read(memberModerationErrorProvider.notifier).state =
                          null,
                ),
              ),
            ),
          ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: message != null,
            child: child,
          ),
        ),
      ],
    );
  }
}
