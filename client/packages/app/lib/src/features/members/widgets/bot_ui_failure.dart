// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The persistent line under a message when a bot's menu entry was refused or
/// went unanswered. See docs/decisions/0045-bot-contributed-ui.md.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/bot_ui_uses.dart';

/// Stays a readable line under the text, not a full-width banner.
const double _maxWidth = 480;

class BotUiFailureLine extends ConsumerWidget {
  const BotUiFailureLine({super.key, required this.messageId});

  final String messageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefix = menuUsePrefix(messageId);
    // Selects the key and the use, which keep their identity, never a fresh entry.
    final key = ref.watch(
      botUiUsesProvider.select(
        (uses) => uses.entries
            .where((e) => e.key.startsWith(prefix) && e.value.failure != null)
            .firstOrNull
            ?.key,
      ),
    );
    final failed = key == null
        ? null
        : ref.watch(botUiUsesProvider.select((uses) => uses[key]));
    if (failed == null) return const SizedBox.shrink();
    final controller = ref.read(botUiUsesProvider.notifier);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxWidth),
        child: AppErrorState(
          message: failed.failure!,
          onRetry: () {
            controller.dismiss(key!);
            unawaited(failed.retry());
          },
          onDismiss: () => controller.dismiss(key!),
        ),
      ),
    );
  }
}
