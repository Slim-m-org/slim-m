// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who is typing in a channel, shown above the composer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../members/providers/member_presence.dart';
import '../../../providers/providers.dart';
import '../providers/typing_controller.dart';

/// From real `typing.started`/`typing.stopped` events; `TypingController`
/// also sends the `typing` frame this client emits while the user types (see
/// `providers/typing_controller.dart`).
///
/// The server fans a typist's own frame back to their own connections too
/// (so a second device can show it), so the caller's own id is dropped here
/// rather than at the source: without it, typing into a channel with nobody
/// else in it - a personal space above all - would read "you are typing"
/// back at you the whole time you typed.
class TypingIndicator extends ConsumerWidget {
  const TypingIndicator({super.key, required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selfId = ref.watch(sessionProvider).tokens?.userId;
    final typingIds = ref
        .watch(typingControllerProvider(channelId))
        .where((id) => id != selfId)
        .toSet();

    // The band reveals and retracts; dots mount only while somebody types.
    return AppRevealBand(
      child: typingIds.isEmpty ? null : _line(context, ref, typingIds),
    );
  }

  Widget _line(BuildContext context, WidgetRef ref, Set<String> typingIds) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final members =
        ref.watch(membersProvider).valueOrNull ?? const <api.UserProfile>[];
    String nameFor(String id) => members
        .firstWhere(
          (m) => m.id == id,
          orElse: () => api.UserProfile(
            id: id,
            username: id,
            displayName: 'Someone',
            createdAt: 0,
          ),
        )
        .displayName;

    final names = typingIds.map(nameFor).toList()..sort();
    final label = names.length == 1
        ? '${names.first} is typing…'
        : '${names.join(', ')} are typing…';

    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s8,
      children: [
        const AppTypingDots(),
        Flexible(
          child: Text(
            label,
            style: AppText.code.copyWith(color: tokens.textSecondary),
          ),
        ),
      ],
    );
  }
}
