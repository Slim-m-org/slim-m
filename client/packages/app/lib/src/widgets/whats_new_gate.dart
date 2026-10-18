// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Wraps the signed-in shell and shows the what's-new sheet the moment
/// [whatsNewControllerProvider] has something pending.
///
/// No route is registered for this: the sheet is not a screen someone
/// navigates to, it is a one-shot notice that appears on top of wherever
/// they already are, the same shape `showPinnedMessagesSheet` and friends
/// already take. `route_reachability_test.dart` only ever needs to see a
/// `Routes.x` reached from somewhere, and there is nothing here to reach.
///
/// `ref.listen` only calls its callback on a change away from the state it
/// started at, never with the initial value, so the controller's own
/// constructor-time check is what has to populate [whatsNewControllerProvider]
/// for this to ever fire, exactly once.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/whats_new_controller.dart';
import '../whats_new/whats_new_content.dart';
import 'whats_new_sheet.dart';

class WhatsNewGate extends ConsumerWidget {
  const WhatsNewGate({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A post-frame callback, since showing a dialog mid-build is not allowed.
    ref.listen<List<WhatsNewEntry>>(whatsNewControllerProvider, (
      previous,
      next,
    ) {
      if (next.isEmpty) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        // The home shows the update as a card, so the dialog would say it twice.
        if (ref.read(whatsNewHomeHostsProvider).present) return;
        unawaited(_showAndMarkSeen(context, ref, next));
      });
    });
    return child;
  }

  Future<void> _showAndMarkSeen(
    BuildContext context,
    WidgetRef ref,
    List<WhatsNewEntry> entries,
  ) async {
    await showWhatsNewSheet(context, entries);
    await ref.read(whatsNewControllerProvider.notifier).markSeen();
  }
}
