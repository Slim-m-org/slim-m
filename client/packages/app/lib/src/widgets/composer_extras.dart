// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's smaller pieces: the text field itself, its markdown key
/// bindings, and the banners above the action bar.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_attachments.dart';
import 'composer_context_menu.dart';
import 'composer_markdown_shortcuts.dart';
import 'staged_attachment_tile.dart';

/// How many characters past [kMessageMaxChars] the given [length] sits, or
/// null when it is within the limit. Runs before the send goes out, so the
/// composer can refuse a doomed request rather than let it fail on the wire.
int? messageLengthOverage(int length) =>
    length > kMessageMaxChars ? length - kMessageMaxChars : null;

/// Below this margin a count is not worth showing at all: an ordinary short
/// message generates no counter.
const _counterWarnMargin = 500;

/// Whether the composer's live character counter is worth showing [length].
bool messageCounterVisible(int length) =>
    length >= kMessageMaxChars - _counterWarnMargin;

/// The composer's live character count, shown only once close enough to
/// [kMessageMaxChars] to matter, so the limit is learned while typing rather
/// than only from the failure a send past it would otherwise be.
class MessageLengthCounter extends StatelessWidget {
  const MessageLengthCounter({super.key, required this.length});

  final int length;

  @override
  Widget build(BuildContext context) {
    if (!messageCounterVisible(length)) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final over = length > kMessageMaxChars;
    return Text(
      '$length / $kMessageMaxChars',
      style: AppText.code.copyWith(
        color: over ? tokens.dangerText : tokens.textSecondary,
      ),
    );
  }
}

/// Whether this platform's primary text input is a soft keyboard, which has
/// no shift key and turns the return key into whatever `textInputAction`
/// asks for.
///
/// Read from the theme rather than `Platform.isX` so a test can override it,
/// and deliberately not from `LayoutClass`: a narrow desktop window is
/// compact but still has a real Enter key. This is input modality, not
/// layout.
bool usesSoftKeyboard(BuildContext context) =>
    switch (Theme.of(context).platform) {
      TargetPlatform.iOS ||
      TargetPlatform.android ||
      TargetPlatform.fuchsia => true,
      _ => false,
    };

/// The composer's text entry: the placeholder, the field, and the one way a
/// return key reaches [onSend] on each platform.
///
/// On a soft keyboard the field asks the engine for a send action, because a
/// raw Enter key event only exists on hardware keyboards. On desktop the
/// action stays null, which leaves the engine inserting newlines and lets
/// [CallbackShortcuts] own plain Enter, so Shift+Enter still falls through.
///
/// Exactly one of those is live at a time. An iPad with a hardware keyboard
/// is a soft-keyboard platform holding a real Enter key, so both would fire
/// for one press, and the send would go out twice.
class ComposerField extends StatefulWidget {
  const ComposerField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.channelName,
    required this.hasText,
    required this.onSend,
    required this.onTyping,
    this.isThread = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String channelName;
  final bool hasText;
  final Future<void> Function() onSend;
  final ValueChanged<String> onTyping;

  /// Whether this field is the docked thread's own copy rather than the
  /// channel's. A docked thread pane sits beside its parent channel
  /// (`home_shell_pane_slots.dart`'s `_ThreadPaneSlot`), so both composers are
  /// on screen at once; [channelName] cannot tell them apart (a thread's is
  /// always blank, same as a DM's - see this file's own note below), so this
  /// flag gives the thread's field a distinct accessible name of its own
  /// instead of the two reading identically to a screen reader or to
  /// anything else that finds a control by name rather than by position.
  final bool isThread;

  @override
  State<ComposerField> createState() => _ComposerFieldState();
}

class _ComposerFieldState extends State<ComposerField> {
  /// See `composer_context_menu.dart`'s doc comment for why the field's
  /// context menu needs this at all: on iOS 16+ it is what makes the system
  /// edit menu offer Paste for an image, which it never does on its own.
  /// A second listener on [ComposerField.focusNode] rather than anything
  /// `Composer` itself has to wire up, since that field is this widget's own
  /// concern and nothing above it needs to know the notifier exists.
  final ClipboardImageStatusNotifier _clipboardImageStatus =
      ClipboardImageStatusNotifier();

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_handleFocusChange);
    _clipboardImageStatus.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (widget.focusNode.hasFocus) unawaited(_clipboardImageStatus.update());
  }

  /// Re-focusing before sending is what keeps the soft keyboard up:
  /// `_finalizeEditing` has already unfocused, and only re-opens the input
  /// connection if the callback focuses the field again.
  void _submit() {
    widget.focusNode.requestFocus();
    unawaited(widget.onSend());
  }

  /// Enter confirms an IME candidate while a composition is open, so it must
  /// not also send the half-composed text.
  void _sendUnlessComposing() {
    if (widget.controller.value.composing.isValid) return;
    unawaited(widget.onSend());
  }

  /// The row's icon buttons are a fixed square (see [AppIconButton]'s own
  /// `outerSize`) at this same touch density, so a one-line field is given
  /// the same floor: short of it, [Stack]'s `centerLeft` alignment centres
  /// the hint and the caret against the icons rather than sitting flush at
  /// the top of space the icons alone are claiming.
  double _minHeight(BuildContext context) =>
      AppTouchTargets.of(context) ? AppSizes.rowTouch : AppSizes.rowPointer;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final soft = usesSoftKeyboard(context);

    return CallbackShortcuts(
      bindings: {
        if (!soft)
          for (final key in const [
            LogicalKeyboardKey.enter,
            LogicalKeyboardKey.numpadEnter,
          ])
            SingleActivator(key): _sendUnlessComposing,
        // Shift+Enter is a hardware-only combination, hence gated the same
        // as plain Enter above; it used to fall through to the field's own
        // newline untouched, which a list continuation now has to pre-empt.
        if (!soft)
          const SingleActivator(LogicalKeyboardKey.enter, shift: true): () =>
              widget.controller.value = applyListAwareEnter(
                widget.controller.value,
              ),
        ...emphasisShortcuts(widget.controller),
      },
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: _minHeight(context)),
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            if (!widget.hasText)
              IgnorePointer(
                child: Text.rich(
                  key: const Key('composer-hint'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  TextSpan(
                    // textSecondary, matching AppInput's hint: this input is
                    // active, and textDisabled's AA exemption does not apply.
                    style: AppText.body.copyWith(color: tokens.textSecondary),
                    // A thread's own channel row carries no name (see
                    // ChannelScreen's channelName), so an unconditional
                    // "#$channelName" left a dangling hash with nothing
                    // after it; a blank name drops the `#name` clause
                    // entirely rather than rendering one with nothing in it.
                    children: [
                      const TextSpan(text: 'Message'),
                      if (widget.channelName.isNotEmpty) ...[
                        const TextSpan(text: ' '),
                        TextSpan(
                          text: '#${widget.channelName}',
                          style: const TextStyle(fontFamily: AppFonts.mono),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            // A stable name, unlike the hint above: it survives typing, and only isThread (not channelName) ever changes it - see the field's own doc comment.
            Semantics(
              label: widget.isThread ? 'Thread composer' : 'Message composer',
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                onChanged: widget.onTyping,
                minLines: 1,
                maxLines: 6,
                keyboardType: TextInputType.multiline,
                textInputAction: soft ? TextInputAction.send : null,
                onSubmitted: soft ? (_) => _submit() : null,
                style: AppText.body.copyWith(color: tokens.textPrimary),
                cursorColor: tokens.accent,
                contextMenuBuilder: (context, state) =>
                    composerContextMenuBuilder(
                      context,
                      state,
                      clipboardHasImage: _clipboardImageStatus.value,
                      offerFormatting: AppTouchTargets.of(context),
                    ),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  // Opts out of the global boxed-input theme; the surrounding
                  // widget draws its own chrome.
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// An inline failure, in the composer's own vertical rhythm. Dismissible only
/// when [onDismiss] is given; the over-limit band below has nothing to
/// dismiss to, since editing the text back under the limit is what clears it.
class ComposerInlineError extends StatelessWidget {
  const ComposerInlineError({
    super.key,
    required this.message,
    this.onDismiss,
    this.autoDismissAfter,
  });

  final String message;
  final VoidCallback? onDismiss;

  /// Set for a transient action failure (a gif that would not attach) so it
  /// clears itself; left null for a live state like the over-limit band,
  /// which clears when the text is edited back under the limit. See
  /// `AppErrorState.autoDismissAfter`.
  final Duration? autoDismissAfter;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.s8),
    child: AppErrorState(
      message: message,
      onDismiss: onDismiss,
      autoDismissAfter: autoDismissAfter,
    ),
  );
}

/// The composer's two optional bands above the action bar: an attachment
/// failure (a picker that would not open, or a clipboard paste that failed),
/// if there is one to show, and the staged-attachment tiles.
///
/// One widget rather than two calls at the build site, since both are
/// "nothing, unless" content and `composer.dart` has no line budget left to
/// spend on laying them out itself.
class ComposerBanners extends StatelessWidget {
  const ComposerBanners({
    super.key,
    required this.attachmentError,
    required this.onDismissAttachmentError,
    required this.overLimitBy,
    required this.slowModeRemainingSeconds,
    required this.stagedAttachments,
    required this.onRemoveAttachment,
    required this.onRetryAttachment,
    this.commandError,
    this.onDismissCommandError,
  });

  final String? attachmentError;
  final VoidCallback onDismissAttachmentError;

  /// A slash command that would not run (a 403, or the module's own error).
  /// Transient like [attachmentError]: the `/command` text stays in the field
  /// so it can be retried, and the band clears itself after a beat.
  final String? commandError;
  final VoidCallback? onDismissCommandError;

  /// How many characters over [kMessageMaxChars] the composed text sits, or
  /// null when it is within the limit. Non-null both disables the send
  /// button and shows this band, so the refusal is never silent.
  final int? overLimitBy;

  /// Seconds left before the channel's slow mode allows another send, or 0
  /// while it is off, this device is exempt, or the interval has already
  /// elapsed - see `slow_mode_controller.dart`. Non-zero both disables the
  /// send button and shows this band, the same "never silent" rule
  /// [overLimitBy] follows.
  final int slowModeRemainingSeconds;
  final List<StagedAttachment> stagedAttachments;
  final ValueChanged<String> onRemoveAttachment;
  final ValueChanged<String> onRetryAttachment;

  @override
  Widget build(BuildContext context) {
    final error = attachmentError;
    final command = commandError;
    final overBy = overLimitBy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppRevealBand(
          child: error == null
              ? null
              : ComposerInlineError(
                  message: error,
                  onDismiss: onDismissAttachmentError,
                  // A gif/attachment action failure is transient and self-correcting - clear it after a beat, unlike the over-limit band below which is a live state.
                  autoDismissAfter: const Duration(seconds: 6),
                ),
        ),
        AppRevealBand(
          child: command == null
              ? null
              : ComposerInlineError(
                  message: command,
                  onDismiss: onDismissCommandError,
                  autoDismissAfter: const Duration(seconds: 6),
                ),
        ),
        AppRevealBand(
          child: overBy == null
              ? null
              : ComposerInlineError(
                  message:
                      'Message is $overBy characters over the '
                      '$kMessageMaxChars-character limit.',
                ),
        ),
        AppRevealBand(
          child: slowModeRemainingSeconds <= 0
              ? null
              : ComposerInlineError(
                  message:
                      'Slow mode: wait ${slowModeRemainingSeconds}s '
                      'before sending again.',
                ),
        ),
        AppRevealBand(
          child: stagedAttachments.isEmpty
              ? null
              : Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.s8),
                  child: Wrap(
                    spacing: AppSpacing.s8,
                    runSpacing: AppSpacing.s8,
                    children: [
                      for (final attachment in stagedAttachments)
                        StagedAttachmentTile(
                          key: ValueKey(attachment.localId),
                          attachment: attachment,
                          onRemove: () =>
                              onRemoveAttachment(attachment.localId),
                          onRetry: () => onRetryAttachment(attachment.localId),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// The composer's secondary actions, off the row rather than on it.
///
/// At touch density five 44pt controls plus their gaps leave a 390pt phone
/// about 90pt of text field, measured, which is not a composer any longer.
/// Attach, poll and code move behind the one button that already means "add
/// something"; emoji and send stay on the row because both are used mid-
/// sentence, where a sheet would cost the caret.
///
/// Attaching splits into two rows rather than one, because a single "Attach
/// a file" hid a choice `file_picker` actually requires on iOS and Android;
/// see `attachment_picker.dart` for why the two cannot share one request.
///
/// [canPasteImage] decides whether the "Paste image" row is worth offering
/// (see `composer_clipboard_paste.dart`'s `composerClipboardPasteAvailable`)
/// and is resolved here, after the sheet is already open, rather than
/// awaited by the caller first: the row simply appears a moment later
/// rather than the whole sheet waiting on a platform-channel round trip to
/// open at all. Deliberate, not an oversight - awaiting it first was tried
/// and reverted; see this file's neighbour for why.
Future<void> showComposerActionsSheet(
  BuildContext context, {
  required VoidCallback onPhotoLibrary,
  required VoidCallback onBrowseFiles,
  required Future<bool> canPasteImage,
  required VoidCallback onPasteImage,
  required VoidCallback onPoll,
  required VoidCallback onCode,
  VoidCallback? onGif,
  VoidCallback? onApps,
}) {
  return showAppSheet<void>(
    context,
    builder: (sheetContext) => FutureBuilder<bool>(
      future: canPasteImage,
      builder: (context, snapshot) {
        final tokens = Theme.of(context).extension<AppTokens>()!;
        final actions = <(IconData, String, VoidCallback)>[
          (AppIcons.image, 'Photo library', onPhotoLibrary),
          (AppIcons.attachFile, 'Browse files', onBrowseFiles),
          if (snapshot.data == true)
            (AppIcons.clipboardPaste, 'Paste image', onPasteImage),
          (AppIcons.poll, 'Create a poll', onPoll),
          (AppIcons.code, 'Insert code', onCode),
          if (onGif != null) (AppIcons.gif, 'GIF', onGif),
          if (onApps != null) (AppIcons.dock, 'Launch an app', onApps),
        ];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s12,
              0,
              AppSpacing.s12,
              AppSpacing.s12,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (icon, label, action) in actions)
                  AppListRow(
                    label: label,
                    leading: Icon(
                      icon,
                      size: AppSizes.icon16,
                      color: tokens.textSecondary,
                    ),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      action();
                    },
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
