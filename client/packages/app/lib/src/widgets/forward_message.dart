// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Forwarding a message: picking where, composing the content, and sending
/// it - three small pieces the context menu's "Forward message" item drives.
///
/// The wire shape is deliberately the plainest one available: an ordinary
/// `POST /channels/{id}/messages` whose content opens with a markdown quote
/// block, never a stretched `reply_to_id`. `reply_to_id` was the other
/// option, and it is refused outright the moment a target crosses channels -
/// `Store::send_message` in `crates/slimm-server/src/store/messages.rs`
/// checks a reply's parent against the *exact* destination channel and
/// answers `SendError::InvalidReplyTarget` otherwise, precisely because
/// letting a reply point at a message the recipient may not even be able to
/// view would be a new cross-channel read this project has never granted.
/// A plain send needs no such check: everything it can name is text this
/// client already has in hand, and the destination picker itself only ever
/// offers a channel or DM the caller can already send to.
///
/// Attachments ride along the same send rather than being re-uploaded:
/// `message_attachments` is a join table keyed `(message_id, sha256)`
/// (`crates/slimm-server/migrations/0002_core_schema.sql`), so the same
/// content-addressed blob can already sit on any number of messages, and
/// `store::attachments::may_link` grants the link the moment the forwarder
/// can view some channel that already has it - which they always can, since
/// they are looking at [message] right now. No server change, no
/// re-upload, no migration.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Unprefixed for the `sendMessage` extension method; `Message` hidden since `slimm_data` has its own, the one this file renders.
import 'package:slimm_api/api.dart' hide Message;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../ids.dart';
import '../providers/forward_targets.dart';
import '../providers/message_extras.dart';
import '../providers/providers.dart';
import '../providers/toasts.dart';
import 'channel_kind_icon.dart';
import 'user_avatar.dart';
import 'run_guarded.dart';
import 'sheet_item_list.dart';

/// Opens the destination picker, then sends the forward. The picker itself
/// runs the send and stays open on a failure (see [_ForwardTargetSheet]),
/// so this only has a success or a cancel left to react to; a cancelled
/// pick, or a pick whose send never succeeded, pops with `null`. A
/// successful pop fires a toast rather than `showAppSnackbar`: with the
/// failure now handled inline in the sheet, this call has no failure
/// branch of its own left to tie it to a SnackBar (see decision 0018).
Future<void> forwardMessage(
  BuildContext context,
  WidgetRef ref,
  Message message,
) async {
  final extras = ref.read(messageExtrasProvider.notifier).extrasFor(message.id);
  final attachmentIds = [for (final a in extras.attachments) a.id];

  final target = await showAppSheet<ForwardTarget>(
    context,
    scrolls: true,
    builder: (context) => _ForwardTargetSheet(
      excludeChannelId: message.channelId,
      forwardedFromId: message.id,
      attachmentIds: attachmentIds,
    ),
  );
  if (target == null || !context.mounted) return;
  ref
      .read(toastsProvider.notifier)
      .show(
        'Forwarded to ${target.label}.',
        severity: AppToastSeverity.success,
      );
}

/// Sends the forward to [target], applying the response the same way any
/// other sent message is: onto the local store and the extras cache, so the
/// transcript (if this forward landed in a channel already open) picks it
/// up without waiting for its own `message.created` broadcast to loop back.
Future<void> _sendForward(
  WidgetRef ref, {
  required ForwardTarget target,
  required String forwardedFromId,
  required String note,
  required List<String> attachmentIds,
}) async {
  final sent = await ref
      .read(apiProvider)
      .sendMessage(
        channelId: target.channelId,
        id: newMessageId(),
        content: note,
        attachmentIds: attachmentIds,
        forwardedFromId: forwardedFromId,
      );
  final store = await ref.read(storeProvider.future);
  await store.applyMessage(sent);
  ref.read(messageExtrasProvider.notifier).applyMessage(sent);
}

const _headingPadding = EdgeInsets.fromLTRB(
  AppSpacing.s16,
  0,
  AppSpacing.s16,
  AppSpacing.s8,
);

/// The destination picker: a search field over every [ForwardTarget], each
/// row sending on tap.
///
/// Unlike the sheet this replaces, tapping a row does not pop immediately -
/// see `docs/design/desktop-vs-mobile.md` rule 4 ("a short task with a
/// submit" gets a `showAppSheet`, kept open through the submit). A picker
/// that popped on tap and only then found out whether the send worked had
/// nowhere left to put a failure but a `SnackBar`, exactly the shape
/// `run_guarded.dart`'s own doc comment warns off and
/// `scripts/check-error-surface.py` exists to keep from creeping back. This
/// sheet stays open, in flight, until the send actually succeeds: a
/// failure renders inline as an [AppErrorState] (via [GuardedActionState]),
/// dismissible, and the same row can simply be tapped again.
class _ForwardTargetSheet extends ConsumerStatefulWidget {
  const _ForwardTargetSheet({
    required this.excludeChannelId,
    required this.forwardedFromId,
    required this.attachmentIds,
  });

  final String excludeChannelId;

  /// The message being forwarded. Only its id travels: the server reads the
  /// original's author, timestamp and text for itself, so this sheet has
  /// nothing to quote and no author to attribute.
  final String forwardedFromId;
  final List<String> attachmentIds;

  @override
  ConsumerState<_ForwardTargetSheet> createState() =>
      _ForwardTargetSheetState();
}

class _ForwardTargetSheetState extends ConsumerState<_ForwardTargetSheet>
    with GuardedActionState<_ForwardTargetSheet> {
  final _searchController = TextEditingController();
  final _noteController = TextEditingController();
  String _query = '';

  /// The target currently sending, or null. Disables every other row while
  /// set, so a fast double-tap on two different rows can never race two
  /// sends from one picker.
  String? _sendingToChannelId;

  @override
  void dispose() {
    _searchController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _send(ForwardTarget target) async {
    clearActionError();
    setState(() => _sendingToChannelId = target.channelId);
    final ok = await guard(
      whatFailed: 'forward the message',
      action: () => _sendForward(
        ref,
        target: target,
        forwardedFromId: widget.forwardedFromId,
        note: _noteController.text.trim(),
        attachmentIds: widget.attachmentIds,
      ),
    );
    if (!mounted) return;
    setState(() => _sendingToChannelId = null);
    if (ok) Navigator.of(context).pop(target);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final ForwardTargetsQuery query = (
      excludeChannelId: widget.excludeChannelId,
      hasAttachments: widget.attachmentIds.isNotEmpty,
    );
    final targets = ref.watch(forwardTargetsProvider(query));

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: _headingPadding,
            child: Text('Forward message', style: AppText.heading),
          ),
          // Before the destinations, not after: tapping a destination is what sends, so anything meant to ride along has to already be written.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
            child: AppInput(
              maxLength: InputLimits.message,
              controller: _noteController,
              placeholder: 'Say something about it (optional)',
              semanticLabel: 'A message to send with this forward',
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
            child: AppInput(
              controller: _searchController,
              placeholder: 'Search channels and DMs',
              icon: Icon(
                AppIcons.search,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              ),
              onChanged: (value) => setState(() => _query = value),
              semanticLabel: 'Search where to forward this',
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
          if (actionError case final error?)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s16,
                0,
                AppSpacing.s16,
                AppSpacing.s8,
              ),
              child: AppErrorState(message: error, onDismiss: clearActionError),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.5,
            ),
            child: AppAsyncView(
              value: AppAsyncState(
                data: targets.valueOrNull,
                error: targets.error,
              ),
              errorMessage: 'Could not load where you can forward this.',
              onRetry: () => ref.invalidate(forwardTargetsProvider(query)),
              emptyMessage: 'Nowhere to forward this to yet.',
              isEmpty: (list) => list.isEmpty,
              data: (context, list) => _buildResults(context, tokens, list),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(
    BuildContext context,
    AppTokens tokens,
    List<ForwardTarget> list,
  ) {
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? list
        : [
            for (final target in list)
              if (target.matches(query)) target,
          ];
    if (filtered.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s16),
          child: Text(
            'No matches.',
            style: TextStyle(color: tokens.textSecondary),
          ),
        ),
      );
    }
    return SheetItemList(
      itemCount: filtered.length,
      itemBuilder: (context, i) {
        final target = filtered[i];
        final sendingHere = _sendingToChannelId == target.channelId;
        final busy = _sendingToChannelId != null;
        return AppListRow(
          // A DM is a person; one generic glyph made them all look alike.
          leading: target.isDm && target.userId != null
              ? UserAvatar.known(
                  userId: target.userId!,
                  avatarUpdatedAt: target.avatarUpdatedAt,
                  name: target.label,
                  size: AppAvatarSize.s24,
                )
              : target.isDm
              ? const Icon(AppIcons.account)
              : ChannelKindIcon(
                  isVoice: target.isVoice,
                  restricted: target.restricted,
                  color: tokens.textSecondary,
                  size: AppSizes.icon20,
                ),
          label: target.label,
          trailing: sendingHere
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onTap: busy ? null : () => unawaited(_send(target)),
        );
      },
    );
  }
}
