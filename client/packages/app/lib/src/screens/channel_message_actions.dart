// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Acting on one message, from a screen that can confirm and can report back.
///
/// `providers/message_actions.dart` is the layer below this one: it applies
/// the optimistic update and lets the request fail up to its caller. These are
/// the callers. Every one of them needs a [BuildContext] to put a dialog or a
/// snackbar in front of somebody, which is the whole reason they could not
/// live down there with the rest.
///
/// Split out of `channel_screen.dart`, where the same try/report block was
/// written five times over. `messageActionsFor` (bottom of this file) is the
/// same kind of split, moved here once adding thread support left no room
/// for it in `channel_screen.dart`'s own 500-line ceiling.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../message_link.dart';
import '../providers/message_actions.dart';
import '../providers/message_selection.dart';
import '../providers/pins_controller.dart';
import '../providers/providers.dart';
import '../providers/toasts.dart';
import '../providers/threads.dart';
import '../routing/breakpoints.dart';
import '../routing/routes.dart';
import '../widgets/app_snackbar.dart';
import '../providers/bot_ui_uses.dart';
import '../widgets/bot_menu_sections.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/forward_message.dart' show forwardMessage;
import '../widgets/message_context_menu.dart';
import '../widgets/run_guarded.dart';
import '../widgets/safety_actions.dart';

/// Runs [action], and on a refusal from the server says so.
///
/// The mounted check is not decoration: every one of these awaits a network
/// round trip, and a user who leaves the channel meanwhile takes the element
/// this would otherwise reach through with them.
Future<void> _reporting(
  BuildContext context,
  String whatFailed,
  Future<void> Function() action,
) async {
  final failure = await runGuarded(whatFailed: whatFailed, action: action);
  if (failure != null && context.mounted) showAppSnackbar(context, failure);
}

/// Saves an inline edit. Unchanged text is not a request.
Future<void> submitMessageEdit(
  WidgetRef ref,
  BuildContext context,
  Message message,
  String content,
) async {
  if (content == message.content) return;
  await _reporting(
    context,
    'save the edit',
    () => editMessageAction(ref, message, content),
  );
}

/// Asks first, because a delete removes the message for everyone.
Future<void> confirmAndDeleteMessage(
  WidgetRef ref,
  BuildContext context,
  Message message,
) async {
  final confirmed = await confirmDangerousAction(
    context,
    title: deleteMessageConfirmTitle,
    message: deleteMessageConfirmMessage,
    confirmLabel: 'Delete',
  );
  if (!confirmed || !context.mounted) return;
  await _reporting(
    context,
    'delete the message',
    () => deleteMessageAction(ref, message),
  );
}

/// Asks, deletes the whole selection in one request, then leaves the mode.
///
/// The selection is read once, before the dialog, so what is deleted is what
/// was counted on the button rather than whatever the set happens to hold
/// after an await. It is cleared only on success: a refused delete leaves the
/// selection intact to retry or cancel, since rebuilding it by hand is the
/// expensive part.
Future<void> confirmAndDeleteSelectedMessages(
  WidgetRef ref,
  BuildContext context, {
  required String channelId,
}) async {
  final ids = ref.read(messageSelectionProvider(channelId)).ids.toList();
  if (ids.isEmpty) return;
  final confirmed = await confirmDangerousAction(
    context,
    title: ids.length == 1
        ? 'Delete message?'
        : 'Delete ${ids.length} messages?',
    message: deleteMessageConfirmMessage,
    confirmLabel: 'Delete',
  );
  if (!confirmed || !context.mounted) return;
  // The container outlives the screen the delete can be left behind by.
  final container = ProviderScope.containerOf(context, listen: false);
  // runGuarded directly rather than _reporting, which cannot say it succeeded.
  final error = messageBulkDeleteErrorProvider(channelId);
  container.read(error.notifier).state = null;
  final failure = await runGuarded(
    whatFailed: ids.length == 1 ? 'delete the message' : 'delete the messages',
    action: () => bulkDeleteMessagesAction(
      container.read,
      channelId: channelId,
      messageIds: ids,
    ),
  );
  if (failure != null) {
    container.read(error.notifier).state = failure;
    return;
  }
  container.read(messageSelectionProvider(channelId).notifier).clear();
}

/// Keeps a message in the caller's own saved list.
///
/// Not a toggle, unlike [toggleMessagePin]. A saved list is private, so the
/// transcript does not know what is in it and asking per message would be a
/// request per row; removing something is done from the saved list itself,
/// where the state is already on screen. The toast is the acknowledgement
/// that a silent success would otherwise leave the user guessing about.
Future<void> saveMessageForLater(
  WidgetRef ref,
  BuildContext context,
  Message message,
) async {
  final failure = await runGuarded(
    whatFailed: 'save the message',
    action: () => ref.read(apiProvider).saveMessage(message.id),
  );
  if (!context.mounted) return;
  if (failure != null) {
    showAppSnackbar(context, failure);
    return;
  }
  ref
      .read(toastsProvider.notifier)
      .show('Saved.', severity: AppToastSeverity.success);
}

/// Copies a link to [message] onto the clipboard.
///
/// Purely local: there is nothing to ask the server for, since the link is built
/// from the deployment address this client is already signed into plus two ids it
/// already has. So unlike its neighbours here it has no failure worth guarding -
/// a clipboard write that goes wrong is not something a retry would fix.
///
/// Confirms with a toast rather than silently, because a clipboard write is
/// invisible: nothing on screen changes, so without it the only way to know it
/// worked is to paste somewhere and look.
Future<void> copyMessageLink(
  WidgetRef ref,
  BuildContext context, {
  required String channelId,
  required Message message,
}) async {
  final link = buildMessageLink(
    server: ref.read(serverUrlProvider),
    channelId: channelId,
    messageId: message.id,
  );
  await Clipboard.setData(ClipboardData(text: link));
  if (!context.mounted) return;
  ref
      .read(toastsProvider.notifier)
      .show('Link copied.', severity: AppToastSeverity.success);
}

/// Pins or unpins, [pinned] being what it is now rather than what to make it.
Future<void> toggleMessagePin(
  WidgetRef ref,
  BuildContext context, {
  required String channelId,
  required Message message,
  required bool pinned,
}) async {
  final controller = ref.read(pinsControllerProvider(channelId).notifier);
  await _reporting(
    context,
    'update the pin',
    () => pinned ? controller.unpin(message.id) : controller.pin(message.id),
  );
}

/// Files a report against a message, once the reporter has given a reason.
///
/// [ref] is unused: `fileReport` takes a [ProviderContainer], derived from
/// [context] below, because this row's context never gets popped out from
/// under it the way the member popover's does. The parameter stays only so
/// this keeps its call site's shape unchanged.
Future<void> reportMessage(BuildContext context, Message message) => fileReport(
  context,
  ProviderScope.containerOf(context, listen: false),
  subject: api.ReportSubject.message,
  subjectId: message.id,
  subjectLabel: 'this message',
);

/// Blocks a message's author. A message with no live author has nobody to
/// block, so it is not offered one.
Future<void> blockMessageAuthor(BuildContext context, Message message) async {
  final authorId = message.authorId;
  if (authorId == null) return;
  await blockUser(
    context,
    ProviderScope.containerOf(context, listen: false),
    authorId,
  );
}

/// Opens (or reuses) the thread hanging off [message], then navigates to it.
///
/// The container rather than [WidgetRef], the same reason [reportMessage]
/// takes one: the row that starts this can be gone (its menu closed) before
/// the request answers, and a container outlives that.
Future<void> openThreadForMessage(BuildContext context, Message message) async {
  final container = ProviderScope.containerOf(context, listen: false);
  String? threadId;
  await _reporting(context, 'open the thread', () async {
    threadId = await openThreadFromMessage(
      container,
      message.channelId,
      message.id,
    );
  });
  if (threadId == null || !context.mounted) return;
  openThreadPresenting(context, container, threadId!);
}

/// Docks the thread beside the transcript where there is room for the pane
/// (UX1), and otherwise pushes the modal `/thread/:id` route - the compact and
/// deep-link path, which the docked provider deliberately does not replace.
void openThreadPresenting(
  BuildContext context,
  ProviderContainer container,
  String threadId,
) {
  final width = MediaQuery.sizeOf(context).width;
  if (LayoutClass.fromWidth(width).fitsThreadPane(width)) {
    dockThread(container, threadId);
  } else {
    GoRouter.of(context).push(Routes.thread(threadId));
  }
}

/// Builds what this viewer may do to [message]: the policy is here rather
/// than in `channel_screen.dart` because that file sits at its own 300-line
/// review budget with no room left, and this is exactly the kind of
/// per-message decision `channel_message_actions.dart` already owns.
/// [onReply] and [onEdit] stay callbacks into the caller because both swap
/// state the screen itself holds (the reply banner, the inline edit field),
/// not state this file has anywhere to keep.
MessageActions messageActionsFor(
  WidgetRef ref,
  BuildContext context,
  Message message, {
  required String channelId,
  required bool channelIsThread,
  required bool hasExistingThread,
  required String? myId,
  required int myPermissions,
  required Set<String> pinnedIds,
  required void Function(Message) onReply,
  required void Function(Message) onEdit,
  List<api.ChannelBotUi> botUi = const [],
}) {
  final pinned = pinnedIds.contains(message.id);
  return MessageActions(
    canReply: canReplyToMessage(message, myPermissions),
    onReply: () => onReply(message),
    canEdit: canEditMessage(message, myId),
    onEdit: () => onEdit(message),
    canDelete: canDeleteMessage(message, myId, myPermissions),
    onDelete: () => unawaited(confirmAndDeleteMessage(ref, context, message)),
    canManagePins: canManageMessagePin(message, myPermissions),
    pinned: pinned,
    onTogglePin: () => unawaited(
      toggleMessagePin(
        ref,
        context,
        channelId: channelId,
        message: message,
        pinned: pinned,
      ),
    ),
    canReport: canReportMessage(message, myId),
    onReport: () => unawaited(reportMessage(context, message)),
    canBlockAuthor: canBlockMessageAuthor(message, myId),
    onBlockAuthor: () => unawaited(blockMessageAuthor(context, message)),
    canOpenThread: canOpenThreadFor(
      message,
      myPermissions,
      channelIsThread: channelIsThread,
    ),
    onOpenThread: () => unawaited(openThreadForMessage(context, message)),
    hasExistingThread: hasExistingThread,
    canCopyLink: canCopyMessageLink(message),
    onCopyLink: () => unawaited(
      copyMessageLink(ref, context, channelId: channelId, message: message),
    ),
    canForward: canForwardMessage(message),
    onForward: () => unawaited(forwardMessage(context, ref, message)),
    canSave: canSaveMessage(message),
    onSave: () => unawaited(saveMessageForLater(ref, context, message)),
    onStartSelecting: canStartSelectingMessages(message, myPermissions)
        ? () => ref
              .read(messageSelectionProvider(channelId).notifier)
              .start(message.id)
        : null,
    botSections: message.pending || message.failed
        ? const []
        : botMenuSections(
            botUi,
            onUse: (bot, entry) => unawaited(
              ref
                  .read(botUiUsesProvider.notifier)
                  .useMenuEntry(
                    channelId: channelId,
                    botId: bot.botUserId,
                    entryId: entry.id,
                    messageId: message.id,
                  ),
            ),
          ),
  );
}
