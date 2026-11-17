// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Forwarding a message: the sheet that previews it, takes an optional note
/// and sends it wherever the person picks, this channel included.
///
/// The send is an ordinary `POST /channels/{id}/messages` naming the original
/// in `forwarded_from_id`; its attachments ride along by id, since the server
/// links the same content-addressed blobs rather than taking a re-upload.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Unprefixed for the `sendMessage` extension method; `Message` hidden since `slimm_data` has its own, the one this file renders.
import 'package:slimm_api/api.dart' hide Message;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../ids.dart';
import '../../../message_preview.dart';
import '../../../providers/providers.dart';
import '../../../providers/toasts.dart';
import '../../../widgets/run_guarded.dart';
import '../../members/providers/user_profiles.dart';
import '../../members/widgets/user_avatar.dart';
import '../providers/forward_targets.dart';
import '../providers/message_api_actions.dart';
import '../providers/message_extras.dart';
import 'author_label.dart';
import 'destination_picker.dart';
import 'message_preview_text.dart';
import 'reply_target_summary.dart' show ReplyAttachmentThumb;

/// Opens the forward sheet (`docs/design/desktop-vs-mobile.md` rule 4: a
/// bottom sheet on a phone, a dialog above it). The sheet sends and stays open
/// on a failure, so this only toasts the success (decision 0018).
Future<void> forwardMessage(
  BuildContext context,
  WidgetRef ref,
  Message message,
) async {
  final extras = ref.read(messageExtrasProvider.notifier).extrasFor(message.id);
  final target = await showAppSheet<ForwardTarget>(
    context,
    scrolls: true,
    builder: (context) => _ForwardSheet(
      message: message,
      attachmentIds: [for (final a in extras.attachments) a.id],
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

/// Applies the sent forward locally, so a transcript already open on its
/// channel shows it without waiting for the broadcast to loop back.
Future<void> _sendForward(
  ProviderContainer container, {
  required ForwardTarget target,
  required String id,
  required String forwardedFromId,
  required String note,
  required List<String> attachmentIds,
}) async {
  final sent = await container
      .read(messageApiActionsProvider)
      .sendMessage(
        channelId: target.channelId,
        id: id,
        content: note,
        attachmentIds: attachmentIds,
        forwardedFromId: forwardedFromId,
      );
  final store = await container.read(storeProvider.future);
  await store.applyMessage(sent);
  container.read(messageExtrasProvider.notifier).applyMessage(sent);
}

@visibleForTesting
const forwardSearchKey = Key('forward-search');

const _sidePadding = EdgeInsets.symmetric(horizontal: AppSpacing.s16);

class _ForwardSheet extends ConsumerStatefulWidget {
  const _ForwardSheet({required this.message, required this.attachmentIds});

  final Message message;
  final List<String> attachmentIds;

  @override
  ConsumerState<_ForwardSheet> createState() => _ForwardSheetState();
}

class _ForwardSheetState extends ConsumerState<_ForwardSheet>
    with GuardedActionState<_ForwardSheet> {
  final _noteController = TextEditingController();
  final _forwardId = RetryId(newMessageId);

  /// Set while a send is in flight, so two quick picks never race two sends.
  String? _sendingToChannelId;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _send(ForwardTarget target) async {
    clearActionError();
    setState(() => _sendingToChannelId = target.channelId);
    final note = _noteController.text.trim();
    final container = ProviderScope.containerOf(context, listen: false);
    final ok = await guard(
      whatFailed: 'forward the message',
      action: () => _sendForward(
        container,
        target: target,
        id: _forwardId.forRequest((channelId: target.channelId, note: note)),
        forwardedFromId: widget.message.id,
        note: note,
        attachmentIds: widget.attachmentIds,
      ),
    );
    if (!mounted) return;
    setState(() => _sendingToChannelId = null);
    if (ok) Navigator.of(context).pop(target);
  }

  @override
  Widget build(BuildContext context) {
    final touch = MediaQuery.sizeOf(context).width < kCompactWidth;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppSheetHeader(
              'Forward message',
              trailing: touch
                  ? null
                  : AppIconButton(
                      icon: AppIcons.dismiss,
                      semanticLabel: 'Close',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
            ),
            Padding(
              // Inset by AppInput's focus-ring gap so its edges line up with the fields.
              padding: _sidePadding.add(
                const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
              ),
              child: _ForwardPreview(message: widget.message),
            ),
            const SizedBox(height: AppSpacing.s8),
            // Above the list: picking a row is what sends.
            Padding(
              padding: _sidePadding,
              child: AppInput(
                maxLength: InputLimits.message,
                controller: _noteController,
                placeholder: 'Add a message (optional)',
                semanticLabel: 'A message to send with this forward',
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
                child: AppErrorState(
                  message: error,
                  onDismiss: clearActionError,
                ),
              ),
            Flexible(
              child: DestinationPicker(
                query: (hasAttachments: widget.attachmentIds.isNotEmpty),
                currentChannelId: widget.message.channelId,
                searchKey: forwardSearchKey,
                busyChannelId: _sendingToChannelId,
                onPick: (target) => unawaited(_send(target)),
                enterLabel: 'Send',
                searchSemanticLabel: 'Search where to forward this',
                errorMessage: 'Could not load where you can forward this.',
                emptyMessage: 'Nowhere to forward this to yet.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What is being forwarded: its author and a few lines of it, or its photo.
class _ForwardPreview extends ConsumerWidget {
  const _ForwardPreview({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final authorId = message.authorId;
    resolveAuthorProfiles(ref, [authorId]);
    final author = authorLabelResolved(
      authorId: authorId,
      cachedDisplayName: message.authorDisplayName,
      resolution: ref.watch(
        batchProfilesControllerProvider.select(
          (m) => authorResolution(m, authorId ?? ''),
        ),
      ),
    );
    final attachments = ref.watch(
      messageExtrasProvider.select(
        (extras) => extras[message.id]?.attachments ?? const [],
      ),
    );
    final snippet = watchPreviewLine(
      ref,
      messageId: message.id,
      content: message.content,
      attachments: attachments,
    );
    final showThumb =
        plainPreview(message.content).isEmpty && attachments.length == 1;
    return DecoratedBox(
      key: const Key('forward-preview'),
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AppSpacing.s8,
          children: [
            if (showThumb)
              ReplyAttachmentThumb(
                attachments: attachments,
                edge: AppSpacing.s40,
              )
            else
              UserAvatar(
                name: author,
                userId: authorId ?? '',
                size: AppAvatarSize.s20,
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: AppSpacing.s4,
                children: [
                  Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: tokens.textPrimary,
                      fontWeight: AppWeights.semi,
                    ),
                  ),
                  if (snippet.isNotEmpty)
                    Text(
                      snippet,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith(color: tokens.textSecondary),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
