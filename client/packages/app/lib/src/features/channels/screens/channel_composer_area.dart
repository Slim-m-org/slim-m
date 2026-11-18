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

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../accounts/providers/account_providers.dart';
import '../../composer/providers/composer_extent.dart';
import '../../messages/providers/message_editing.dart';
import '../../messages/providers/message_selection.dart';
import '../../voice/providers/voice_controller.dart';
import '../../voice/widgets/call_keyboard_pill.dart';
import '../../../routing/breakpoints.dart';
import '../../../widgets/dock_height_reporter.dart';
import '../../../providers/admin_providers.dart';
import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';
import '../../composer/widgets/composer.dart';
import '../../composer/widgets/composer_attachments.dart' show StagedSend;
import '../../composer/widgets/composer_autofocus.dart';
import '../../composer/widgets/composer_read_only_bar.dart';
import '../../../permissions.dart';
import '../providers/channel_permissions.dart';
import '../../messages/widgets/message_selection_bar.dart';
import '../../messages/widgets/reply_banner.dart';
import '../../members/widgets/timeout_banner.dart';
import '../../share/providers/incoming_share.dart';
import 'channel_message_actions.dart';

/// Shown when the message being replied to is deleted while the reply is typed.
const replyGoneNotice = 'The message you were replying to was deleted.';

/// Shown when a message is deleted elsewhere while it is being edited here.
const editGoneNotice = 'Your edit was not saved: the message was deleted.';

/// Shown when files are shared to a channel where Send is not allowed.
const shareRefusedNotice =
    'The shared files were not attached: you cannot send messages here.';

class ChannelComposerArea extends ConsumerStatefulWidget {
  const ChannelComposerArea({
    required this.channelId,
    required this.controller,
    required this.channelName,
    required this.onSend,
    required this.replyingTo,
    required this.onCancelReply,
    this.autofocus = false,
    this.focusRequests,
    this.reportsExtent = true,
    super.key,
  });

  final String channelId;
  final TextEditingController controller;
  final String channelName;
  final Future<void> Function(StagedSend) onSend;
  final Message? replyingTo;
  final VoidCallback onCancelReply;

  /// See [ComposerAutofocus]; only the docked thread pane sets it.
  final bool autofocus;

  /// Fires when something outside asks to type here, such as Reply.
  final Listenable? focusRequests;

  /// Whether this is the main pane's stack, which floating cards rest above; a docked thread's is not.
  final bool reportsExtent;

  @override
  ConsumerState<ChannelComposerArea> createState() =>
      _ChannelComposerAreaState();
}

class _ChannelComposerAreaState extends ConsumerState<ChannelComposerArea> {
  StreamSubscription<api.ServerEvent>? _deletes;

  /// The last settled answer to whether Send is missing here; see [_readOnlyNow].
  bool _readOnly = false;

  /// Why a reply, an edit or a share in progress just went away, until dismissed.
  String? _goneNotice;

  @override
  void initState() {
    super.initState();
    _deletes = ref.read(liveEventsProvider).listen((event) {
      if (event is api.MessageDeleted) _onDeleted(event.messageId);
    });
  }

  @override
  void didUpdateWidget(ChannelComposerArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.replyingTo != null && oldWidget.replyingTo == null) {
      _goneNotice = null;
    }
  }

  @override
  void dispose() {
    unawaited(_deletes?.cancel());
    super.dispose();
  }

  /// A reply or an edit whose message was deleted elsewhere would otherwise
  /// send as a reply to nothing, or vanish with the row it was typed into.
  void _onDeleted(String messageId) {
    if (!mounted) return;
    final editing = editingMessageIdProvider(widget.channelId);
    if (ref.read(editing) == messageId) {
      ref.read(editing.notifier).state = null;
      setState(() => _goneNotice = editGoneNotice);
    } else if (widget.replyingTo?.id == messageId) {
      widget.onCancelReply();
      setState(() => _goneNotice = replyGoneNotice);
    }
  }

  // The main pane only: a docked thread shares the call's channel page and its keyboard.
  bool _showsCallPill(BuildContext context) {
    if (!widget.reportsExtent) return false;
    final (state, callChannelId) = ref.watch(
      voiceControllerProvider.select((s) => (s.state, s.channelId)),
    );
    return showsCallKeyboardPill(
      width: MediaQuery.sizeOf(context).width,
      keyboardUp: ShellKeyboard.isUp(context),
      state: state,
      callChannelId: callChannelId,
      channelId: widget.channelId,
      callElsewhere: ref.watch(
        accountsSnapshotProvider.select((s) => s.callElsewhere != null),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = _content(context);
    if (!widget.reportsExtent) return content;
    return DockHeightReporter(
      reservation: composerExtentProvider,
      child: content,
    );
  }

  Widget _content(BuildContext context) {
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
    // Refetches me when a timeout ends, which is also what rebuilds this so its banner leaves on time.
    ref.watch(timeoutExpiryWatcherProvider);
    final me = ref.watch(meProvider).valueOrNull;
    final timedOutUntil = me?.timedOutUntil;
    final stillTimedOut =
        timedOutUntil != null &&
        timedOutUntil > clock.now().millisecondsSinceEpoch;
    final readOnly = _readOnlyNow(channelId);
    if (readOnly) _refuseShare(channelId);
    final composer = Composer(
      controller: widget.controller,
      channelId: channelId,
      channelName: widget.channelName,
      onSend: widget.onSend,
      replyToId: widget.replyingTo?.id,
      onCommandPosted: widget.onCancelReply,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_showsCallPill(context)) const CallKeyboardPill(),
        AppRevealBand(
          child: stillTimedOut
              ? TimeoutBanner(until: timedOutUntil, reason: me?.timeoutReason)
              : null,
        ),
        AppRevealBand(
          child: _goneNotice == null
              ? null
              : Padding(
                  // The composer's gutter, so the notice lines up with the field or bar below it.
                  padding: EdgeInsets.symmetric(
                    horizontal: paneGutterOf(context),
                    vertical: AppSpacing.s8,
                  ),
                  child: AppErrorState(
                    message: _goneNotice!,
                    onDismiss: () => setState(() => _goneNotice = null),
                  ),
                ),
        ),
        AppRevealBand(
          child: widget.replyingTo == null
              ? null
              : ReplyBanner(
                  message: widget.replyingTo!,
                  onCancel: widget.onCancelReply,
                ),
        ),
        // Not mounted at all, so no drop or share can stage into it; the staging and the draft outlive it.
        if (readOnly)
          const ComposerReadOnlyBar()
        else
          ComposerAutofocus(
            channelId: channelId,
            focusOnMount: widget.autofocus,
            focusRequests: widget.focusRequests,
            child: composer,
          ),
      ],
    );
  }

  /// A share handed here has no composer to land in, so it is dropped with a word rather than left waiting.
  void _refuseShare(String channelId) {
    bool forHere() => ref.read(shareHandoffProvider)?.channelId == channelId;
    if (ref.watch(shareHandoffProvider)?.channelId != channelId) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !forHere()) return;
      ref.read(shareHandoffProvider.notifier).state = null;
      setState(() => _goneNotice = shareRefusedNotice);
    });
  }

  /// Whether Send is missing here, read live; a timeout shows its own banner instead.
  /// While either answer is refetched the last one stands, so a timeout ending never flashes the bar.
  bool _readOnlyNow(String channelId) {
    final me = ref.watch(meProvider);
    final bits = ref.watch(channelPermissionsProvider(channelId));
    if (me.isLoading || bits.isLoading || bits.hasError) return _readOnly;
    const send = Perm.sendMessages | Perm.administrator;
    return _readOnly =
        me.valueOrNull?.timedOutUntil == null &&
        bits.hasValue &&
        bits.requireValue & send == 0;
  }
}
