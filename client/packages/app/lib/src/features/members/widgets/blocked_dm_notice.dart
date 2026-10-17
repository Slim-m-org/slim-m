// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a DM with a blocked person shows in place of its composer.
///
/// The channel itself is frozen server-side for exactly this pair
/// (`store/dms.rs` denies SEND, ADD_REACTIONS and ATTACH_FILES both
/// directions), so a composer here would only ever fail on send; this says
/// why instead of leaving a live-looking field that cannot work, and offers
/// the one way out. It mutates [blocksProvider] directly rather than through
/// `safety_actions.dart`'s `unblockUser`: that helper is built for a popover
/// that has already closed by the time its request answers, so it can only
/// ever report a failure as a `SnackBar`. This widget stays mounted for as
/// long as the block does, so a failure belongs inline, in an
/// [AppErrorState], the same choice `run_guarded.dart`'s own doc comment
/// draws between the two.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/blocks_controller.dart';
import '../../../widgets/run_guarded.dart';

class BlockedDmNotice extends ConsumerStatefulWidget {
  const BlockedDmNotice({required this.userId, required this.name, super.key});

  /// The blocked participant's id, for the unblock call.
  final String userId;

  /// The blocked participant's display name.
  final String name;

  @override
  ConsumerState<BlockedDmNotice> createState() => _BlockedDmNoticeState();
}

class _BlockedDmNoticeState extends ConsumerState<BlockedDmNotice>
    with GuardedActionState<BlockedDmNotice> {
  bool _busy = false;

  Future<void> _unblock() async {
    setState(() => _busy = true);
    // A success updates blocksProvider, which is what swaps this notice out.
    await guard(
      whatFailed: 'unblock that user',
      action: () => ref.read(blocksProvider.notifier).unblock(widget.userId),
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpacing.s16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCallout(
          tone: AppCalloutTone.warn,
          child: Text(
            'You have blocked ${widget.name}. Nothing sent here would reach '
            'them, so there is no composer to send from.',
          ),
        ),
        const SizedBox(height: AppSpacing.s8),
        AppButton(
          label: 'Unblock ${widget.name}',
          onPressed: _busy ? null : _unblock,
        ),
        if (actionError != null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(message: actionError!, onDismiss: clearActionError),
        ],
      ],
    ),
  );
}
