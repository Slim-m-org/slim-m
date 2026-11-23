// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The header's "Alex marked this" for a few seconds after a mark, or why one
/// was not made. It never says "clip": that word is the soundboard's.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/session_provider.dart';
import '../../members/providers/user_profiles.dart';
import '../providers/call_mark_chip.dart';

const callMarkChipKey = Key('call-mark-chip');

/// What the chip says about [chip], [me] being this account.
String callMarkChipText(CallMarkChip chip, {String? me, String? name}) {
  if (chip.notice case final notice?) return notice;
  if (chip.authorId == me) return chip.note ? 'Note saved' : 'Marked';
  final who = name ?? 'Someone';
  return chip.note ? '$who saved a note' : '$who marked this';
}

class CallMarkChipView extends ConsumerWidget {
  const CallMarkChipView({super.key, required this.channelId, this.style});

  final String channelId;
  final TextStyle? style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(callMarkChipProvider(channelId), (_, chip) {
      if (chip != null) _announce(context, ref, chip);
    });
    final chip = ref.watch(callMarkChipProvider(channelId));
    if (chip == null) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final text = _text(ref, chip, watch: true);
    return Row(
      key: callMarkChipKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          chip.notice != null
              ? AppIcons.info
              : chip.note
              ? AppIcons.callNote
              : AppIcons.callMark,
          size: AppSizes.icon12,
          color: tokens.textSecondary,
        ),
        const SizedBox(width: AppSpacing.s4),
        Text(text, style: style),
      ],
    );
  }

  String _text(WidgetRef ref, CallMarkChip chip, {bool watch = false}) {
    final me = ref.read(sessionProvider).tokens?.userId;
    final author = chip.authorId;
    final profile = author == null
        ? null
        : watch
        ? ref.watch(userProfileProvider(author))
        : ref.read(userProfileProvider(author));
    return callMarkChipText(
      chip,
      me: me,
      name: profile?.valueOrNull?.displayName,
    );
  }

  void _announce(BuildContext context, WidgetRef ref, CallMarkChip chip) {
    if (!MediaQuery.supportsAnnounceOf(context)) return;
    final view = View.maybeOf(context);
    if (view == null) return;
    final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
    final text = _text(ref, chip);
    unawaited(SemanticsService.sendAnnouncement(view, text, direction));
  }
}
