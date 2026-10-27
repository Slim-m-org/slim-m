// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer text field and the soft-keyboard check that decides how Enter behaves.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_code_fence.dart';
import 'composer_context_menu.dart';
import 'composer_markdown_shortcuts.dart';
import 'composer_scrollbar.dart';

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
    this.scrollController,
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

  /// Driven by an outer scrollbar that owns the thumb; null leaves the
  /// field's own scrolling and thumb untouched.
  final ScrollController? scrollController;

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
    final value = widget.controller.value;
    if (value.composing.isValid) return;
    if (caretInOpenFence(value)) {
      widget.controller.value = newlineInFence(value);
      return;
    }
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
        // Sends even from inside an open code block, where Enter types a newline.
        if (!soft)
          for (final modifier in const [(true, false), (false, true)])
            SingleActivator(
              LogicalKeyboardKey.enter,
              control: modifier.$1,
              meta: modifier.$2,
            ): () =>
                unawaited(widget.onSend()),
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
              child: ScrollbarFreeScope(
                active: widget.scrollController != null,
                child: TextField(
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  onChanged: widget.onTyping,
                  minLines: 1,
                  maxLines: 6,
                  scrollController: widget.scrollController,
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
            ),
          ],
        ),
      ),
    );
  }
}

/// An inline failure, in the composer's own vertical rhythm. Dismissible only
/// when [onDismiss] is given; the over-limit band below has nothing to
