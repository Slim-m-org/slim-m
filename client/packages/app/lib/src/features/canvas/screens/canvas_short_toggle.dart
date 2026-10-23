// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member-list toggle a short window keeps once its header is gone.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../channels/providers/channel_by_id_provider.dart';
import '../../members/widgets/member_list_toggle.dart';

/// Floats at the pane's top right, in the board's letterbox, where [CanvasBar] would have hosted it.
class CanvasShortToggle extends ConsumerWidget {
  const CanvasShortToggle({super.key, required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDm =
        ref.watch(channelByIdProvider(channelId)).valueOrNull?.kind == 'dm';
    if (isDm || !MemberListToggle.fits(context)) {
      return const SizedBox.shrink();
    }
    return const Positioned(
      top: AppSpacing.s8,
      right: AppSpacing.s8,
      child: MemberListToggle(),
    );
  }
}
