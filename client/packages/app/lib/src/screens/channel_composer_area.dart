// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Everything below the transcript: the reply banner and composer normally,
/// and the selection bar while messages are being picked for deletion.
///
/// One slot with two states rather than a stack, because the two are
/// mutually exclusive in fact: nothing can be composed into a transcript that
/// is being selected out of, and a reply banner left showing would name a
/// message the send button can no longer act on.
///
/// Extracted from `channel_screen.dart` rather than added to it. That file
/// sits at a 500-line hard ceiling with single digits to spare, and the
/// selection branch does not fit; the same pressure already moved
/// `messageActionsFor` into `channel_message_actions.dart`. It lives beside
/// the screen rather than in `widgets/` because deleting a selection is a
/// screen-level act - it confirms, reports failure, and leaves the mode.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/message_selection.dart';
import '../providers/providers.dart';
import '../widgets/composer.dart';
import '../widgets/composer_autofocus.dart';
import '../widgets/ephemeral_tray.dart';
import '../widgets/message_selection_bar.dart';
import '../widgets/reply_banner.dart';
import '../widgets/timeout_banner.dart';
import 'channel_message_actions.dart';

class ChannelComposerArea extends ConsumerStatefulWidget {
  const ChannelComposerArea({
    required this.channelId,
    required this.controller,
    required this.channelName,
    required this.onSend,
    required this.replyingTo,
    required this.onCancelReply,
    this.autofocus = false,
    super.key,
  });

  final String channelId;
  final TextEditingController controller;
  final String channelName;
  final Future<void> Function(List<String>) onSend;
  final Message? replyingTo;
  final VoidCallback onCancelReply;

  /// See [ComposerAutofocus]; only the docked thread pane sets it.
  final bool autofocus;

  @override
  ConsumerState<ChannelComposerArea> createState() =>
      _ChannelComposerAreaState();
}

class _ChannelComposerAreaState extends ConsumerState<ChannelComposerArea> {
  Timer? _expiry;
  int? _expiryFor;

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  /// Rebuilds once at [until] so the banner leaves with the timeout, not at the next unrelated rebuild.
  void _scheduleExpiry(int? until) {
    if (until == _expiryFor) return;
    _expiry?.cancel();
    _expiryFor = until;
    if (until == null) return;
    final remaining = until - DateTime.now().millisecondsSinceEpoch;
    if (remaining <= 0) return;
    _expiry = Timer(Duration(milliseconds: remaining), () {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final channelId = widget.channelId;
    if (ref.watch(messageSelectionProvider(channelId)).active) {
      final error = messageBulkDeleteErrorProvider(channelId);
      final failure = ref.watch(error);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (failure != null)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.s8),
              child: AppErrorState(
                message: failure,
                onDismiss: () => ref.read(error.notifier).state = null,
              ),
            ),
          MessageSelectionBar(
            channelId: channelId,
            onDelete: () => confirmAndDeleteSelectedMessages(
              ref,
              context,
              channelId: channelId,
            ),
          ),
        ],
      );
    }
    final me = ref.watch(meProvider).valueOrNull;
    final timedOutUntil = me?.timedOutUntil;
    _scheduleExpiry(timedOutUntil);
    final stillTimedOut =
        timedOutUntil != null &&
        timedOutUntil > DateTime.now().millisecondsSinceEpoch;
    final composer = Composer(
      controller: widget.controller,
      channelId: channelId,
      channelName: widget.channelName,
      onSend: widget.onSend,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppRevealBand(
          child: stillTimedOut
              ? TimeoutBanner(until: timedOutUntil, reason: me?.timeoutReason)
              : null,
        ),
        AppRevealBand(
          child: widget.replyingTo == null
              ? null
              : ReplyBanner(
                  message: widget.replyingTo!,
                  onCancel: widget.onCancelReply,
                ),
        ),
        EphemeralTray(channelId: channelId),
        if (widget.autofocus)
          ComposerAutofocus(channelId: channelId, child: composer)
        else
          composer,
      ],
    );
  }
}
