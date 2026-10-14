// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile card's box for what a member is listening to or playing.
///
/// Absent when there is none, like every other piece of the card. It reads
/// its own provider so the card's parent does not rebuild on a track change.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/presence_activity.dart';
import 'activity_card.dart';

class MemberProfileActivity extends ConsumerWidget {
  const MemberProfileActivity({super.key, required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activity = ref.watch(memberActivityProvider(userId));
    if (activity == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s12,
      ),
      child: ActivityCard(activity: activity, boxed: true),
    );
  }
}
