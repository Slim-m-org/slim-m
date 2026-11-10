// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Share to": where a share from the OS sheet goes.
///
/// A routed page rather than a sheet (desktop-vs-mobile rule 5): the person
/// arrives straight from another app with nothing of ours behind it, so the
/// picker is the place, full screen on a phone and a floating panel on a wide
/// window. The conversation list is the forward picker's, shared with it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/close_screen.dart';
import '../../../routing/routes.dart';
import '../../accounts/providers/account_providers.dart';
import '../providers/incoming_share.dart';
import '../widgets/share_destination_step.dart';
import '../widgets/share_server_step.dart';

class ShareToScreen extends ConsumerWidget {
  const ShareToScreen({super.key});

  /// What the person is told when the other app shared nothing the OS let us read.
  static const unreadableMessage =
      'The app that shared this did not let slim-m read it.';

  void _cancel(BuildContext context, WidgetRef ref) {
    // Cleared first: the router sends the person back here while a share is pending.
    ref.read(pendingShareProvider.notifier).state = null;
    closeScreen(context, Routes.channels);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingShareProvider);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel(context, ref);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Share to'),
          leading: BackToButton(
            tooltip: 'Cancel sharing',
            fallback: Routes.channels,
            onBack: () => _cancel(context, ref),
          ),
        ),
        body: AppContentColumn(
          child: SafeArea(
            top: false,
            child: pending == null
                ? const SizedBox.shrink()
                : _body(context, ref, pending),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, PendingShare pending) {
    final share = pending.share;
    if (!share.hasFiles && !share.hasText) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.s16),
        child: AppErrorState(
          message: unreadableMessage,
          dismissLabel: 'Close',
          onDismiss: () => _cancel(context, ref),
        ),
      );
    }
    final servers = ref.watch(
      accountsSnapshotProvider.select(
        (snapshot) => snapshot.entries.where((e) => e.signedIn).length,
      ),
    );
    return !pending.serverChosen && servers > 1
        ? ShareServerStep(share: share)
        : ShareDestinationStep(share: share);
  }
}
