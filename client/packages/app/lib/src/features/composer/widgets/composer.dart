// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The message composer: a bordered card, its affordances, and the hint row
/// beneath it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Unaliased: `uploadAttachment` is an extension method, visible only where imported.
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../members/providers/bot_commands.dart';
import '../providers/composer_attachment_drop.dart';
import '../../modules/providers/app_launch.dart';
import '../../../routing/breakpoints.dart';
import '../providers/slash_command.dart';
import '../../channels/providers/slow_mode_controller.dart';
import '../../messages/providers/typing_controller.dart';
import '../../messages/widgets/attachment_picker.dart';
import '../../channels/widgets/channel_rail_frame.dart' show serverInfoProvider;
import 'composer_action_bar.dart';
import 'composer_attachment_actions.dart';
import 'composer_attachments.dart';
import 'composer_autocomplete_controller.dart';
import 'composer_autocomplete_watch.dart';
import 'composer_autocomplete.dart';
import 'composer_autocomplete_items.dart';
import 'composer_bot_mention_help.dart';
import 'composer_bot_mentions.dart';
import 'composer_clipboard_image.dart';
import 'composer_clipboard_paste.dart';
import 'composer_code_blocks.dart';
import '../../settings/providers/ui_sound_settings.dart'
    show messageSentSignalProvider;
import 'composer_send_focus.dart';
import 'composer_drop_registration.dart';
import 'composer_extras.dart';
import 'composer_edit_last.dart';
import 'composer_key_handler.dart';
import 'composer_focus_registration.dart';
import 'composer_mention_help_state.dart';
import 'composer_photo_strip.dart';
import 'composer_slash.dart';
import 'composer_text_stats.dart';
import '../../emoji/widgets/emoji_picker.dart';
import 'composer_gif_command.dart';
import '../../../widgets/text_insert.dart';
import '../../messages/widgets/typing_indicator.dart';

class Composer extends ConsumerStatefulWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.channelId,
    required this.channelName,
    required this.onSend,
    this.replyToId,
    this.onCommandPosted,
    this.clipboardPasteStart = startClipboardImagePaste,
    this.clipboardPasteStop = stopClipboardImagePaste,
  });

  final TextEditingController controller;
  final String channelId;
  final String channelName;

  /// Sends the composed text plus whatever attachments were staged before
  /// the send. Ids are already-uploaded attachment ids (see
  /// `SlimmApiAttachments.uploadAttachment`); staging happens here so the
  /// upload finishes before the send request ever goes out.
  /// The send button is disabled while anything staged has not resolved to
  /// an id yet, so this never receives fewer ids than what is visibly
  /// attached.
  final Future<void> Function(StagedSend attachments) onSend;

  /// The message a slash command's output replies to, and what runs once it posted.
  final String? replyToId;
  final VoidCallback? onCommandPosted;

  /// The Ctrl+V seam (see `composer_clipboard_image.dart`): real on web, a
  /// no-op everywhere else. Parameters rather than a direct call so a test
  /// can hand over a fake that fires synchronously, since nothing about a
  /// real browser paste event can be produced from a widget test.
  final void Function(PastedImageHandler onImage) clipboardPasteStart;

  /// Takes the same callback [clipboardPasteStart] was given, which is also
  /// the ownership token that stops this from tearing down a *different*
  /// caller's still-active registration - see the web implementation's own
  /// doc for the race this closes.
  final void Function(PastedImageHandler onImage) clipboardPasteStop;

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  ComposerTextStats _stats = ComposerTextStats.of('');
  late AttachmentStagingController _attachments;

  /// Shown inline above the action bar: a picker that would not open, or a
  /// clipboard paste that failed. Both are "could not get you an
  /// attachment", the one band `ComposerBanners` reserves for it.
  String? _attachmentError;
  late final FocusNode _focus = FocusNode(onKeyEvent: _keys.handle);
  late final _keys = ComposerKeyHandler(
    text: widget.controller,
    autocomplete: _autocomplete,
    onPasteChord: () => unawaited(
      pasteClipboardImageFromKeystroke(
        _actions.stageAttachment,
        _setAttachmentError,
      ),
    ),
    onEditLast: () =>
        editLastOwnMessage(ref, widget.channelId, isMounted: () => mounted),
    onAccept: _accept,
  );
  late final _actions = ComposerAttachmentActions(
    ref: ref,
    context: () => context,
    focus: _focus,
    attachments: () => _attachments,
    setError: _setAttachmentError,
    isMounted: () => mounted,
  );
  final _pickerController = ComposerPickerController();
  late final _codePaste = ComposerCodePaste(widget.controller);

  /// `Version.gifSearchEnabled`, refreshed in [build]; see [_openActions].
  bool _gifSearchEnabled = false;

  /// Seconds left before slow mode allows another send, refreshed in
  /// [build] from [slowModeRemainingSecondsProvider]; see [_canSend].
  int _slowModeRemaining = 0;

  final _focusRegistration = ComposerFocusRegistration();

  /// Keyed by [Composer.channelId]; `channel_attachment_drop_zone.dart`
  /// reaches this composer's staging through it.
  final _drop = ComposerDropRegistration();

  final _autocomplete = ComposerAutocompleteController();
  List<SlashCommand> _slashCommands = const [];
  List<App> _apps = const [];
  List<ChannelBotCommand> _botCommands = const [];

  final _mentionHelp = ComposerMentionHelp();
  String? _commandError;

  /// True while a command awaits its result, so a second send cannot rerun it.
  bool _commandRunning = false;

  /// A staged file is sendable on its own: a photo needs no caption, and the
  /// server accepts an empty body precisely when attachments ride along.
  /// Blocked while anything staged is still uploading or has failed, or a
  /// send would go out missing whatever has not resolved to an id yet.
  /// Also blocked over the character limit, so a doomed request never
  /// reaches the wire at all; see [ComposerBanners]'s `overLimitBy` band for
  /// where that refusal is explained.
  bool get _canSend =>
      !_commandRunning &&
      (_stats.hasSendableText || !_attachments.isEmpty) &&
      !_attachments.hasBlockingAttachment &&
      _stats.overBy == null &&
      _slowModeRemaining <= 0;

  @override
  void initState() {
    super.initState();
    _autocomplete.addListener(_handleAutocompleteChange);
    _attachments = ref.read(attachmentStagingProvider(widget.channelId))
      ..addListener(_handleAttachmentsChange);
    _stats = ComposerTextStats.of(widget.controller.text);
    widget.controller.addListener(_handleChange);
    _focus.addListener(_handleFocusChange);
    _focusRegistration.bind(ref, _focus, isMounted: () => mounted);
    _rebindDropTarget();
  }

  @override
  void didUpdateWidget(covariant Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Each channel keeps its own staging; see attachmentStagingProvider.
    if (oldWidget.channelId != widget.channelId) {
      _attachments.removeListener(_handleAttachmentsChange);
      _attachments = ref.read(attachmentStagingProvider(widget.channelId))
        ..addListener(_handleAttachmentsChange);
      setState(() {
        _attachmentError = null;
        _commandError = null;
        _mentionHelp.clear();
      });
      _autocomplete.resetSelection();
      _rebindDropTarget();
    }
  }

  void _rebindDropTarget() => _drop.bind(
    ref: ref,
    channelId: widget.channelId,
    target: () => ComposerAttachmentDropTarget(
      stage: _actions.stageAttachment,
      stageFile: _actions.stageFile,
      setError: _setAttachmentError,
    ),
    isMounted: () => mounted,
  );

  @override
  void dispose() {
    _focusRegistration.release(_focus);
    _drop.release();
    widget.controller.removeListener(_handleChange);
    _focus.removeListener(_handleFocusChange);
    widget.clipboardPasteStop(_actions.handlePastedImage);
    _autocomplete.dispose();
    _focus.dispose();
    _pickerController.dispose();
    _codePaste.dispose();
    _attachments.removeListener(_handleAttachmentsChange);
    super.dispose();
  }

  /// Every staging change (a pick appearing, an upload settling, a retry or
  /// a removal) rebuilds through here rather than a `setState` at each call
  /// site, so a state the controller reaches on its own (an upload finally
  /// resolving) repaints exactly like one a tap caused directly.
  void _handleAttachmentsChange() {
    if (mounted) setState(() {});
  }

  void _handleAutocompleteChange() {
    if (mounted) setState(() {});
  }

  /// Ctrl+V only reaches an image while this field genuinely has focus: the
  /// seam behind [Composer.clipboardPasteStart] is a single global listener
  /// (see `composer_clipboard_image_web.dart`), so it has to be handed off
  /// on every focus change rather than left running for the widget's whole
  /// life.
  void _handleFocusChange() {
    if (_focus.hasFocus) {
      widget.clipboardPasteStart(_actions.handlePastedImage);
    } else {
      widget.clipboardPasteStop(_actions.handlePastedImage);
    }
  }

  void _handleChange() {
    final stats = ComposerTextStats.of(widget.controller.text);
    final query = composerQueryAt(
      widget.controller.text,
      widget.controller.selection.baseOffset,
      _botCommands,
    );
    final changed = stats.changedFrom(_stats) || query != _autocomplete.query;
    final newlyMentioned = _mentionHelp.unseen(
      mentionedBotUsernames(
        widget.controller.text,
        _botCommands.map((c) => c.botUsername),
      ),
    );
    if (!changed && newlyMentioned.isEmpty) return;
    _autocomplete.setQuery(query);
    setState(() {
      _stats = stats;
      if (newlyMentioned.isNotEmpty) _mentionHelp.show(newlyMentioned);
    });
  }

  void _accept(AutocompleteSuggestion suggestion) => _autocomplete.accept(
    suggestion,
    widget.controller,
    onGif: () => _openGifSearch(''),
    onInserted: _focus.requestFocus,
  );

  /// Replaces the current selection (or inserts at the caret) and leaves the
  /// caret [caretOffset] characters after the start of what was inserted.
  void _insert(String text, {int? caretOffset}) =>
      insertAtSelection(widget.controller, text, caretOffset: caretOffset);

  void _insertCodeFence() =>
      unawaited(insertCodeFromPicker(context, widget.controller, _focus));

  /// Touch density only: the Space's own emoji; native ones come from the
  /// keyboard. Desktop width reaches `ComposerPickerButton`'s panel instead.
  void _pickEmoji() =>
      unawaited(showSpaceEmojiSheet(context, onSelect: _insertPickedEmoji));

  void _insertPickedEmoji(String emoji) {
    _focus.requestFocus();
    _insert(emoji);
  }

  /// Re-focuses first so a soft keyboard stays up across the send, matching
  /// what the field's own submit action does.
  void _sendFromButton() {
    reattachFieldAfterButtonSend(context, _focus);
    unawaited(_send());
  }

  void _setAttachmentError(String? message) {
    if (mounted) setState(() => _attachmentError = message);
  }

  void _openActions() => _actions.openActions(
    channelId: widget.channelId,
    gifSearchEnabled: _gifSearchEnabled,
    apps: _apps,
    onInsertCode: _insertCodeFence,
    onCommandError: _reportCommandError,
  );

  void _onTyping(String _) => ref
      .read(typingControllerProvider(widget.channelId).notifier)
      .notifyTyping();

  void _reportCommandError(String message) {
    if (mounted) setState(() => _commandError = message);
  }

  void _openGifSearch(String query) => _pickerController.openGifSearch(
    context,
    query,
    onSelectEmoji: _insertPickedEmoji,
    onPickedGif: _actions.stageGif,
  );

  Future<void> _send() async {
    if (!_canSend) return;
    final gifQuery = _gifSearchEnabled && _attachments.isEmpty
        ? gifCommandQuery(widget.controller.text)
        : null;
    if (gifQuery != null) {
      widget.controller.clear();
      _openGifSearch(gifQuery);
      return;
    }
    final staging = _attachments;
    final bool handled;
    _commandRunning = true;
    try {
      handled = await runComposedCommand(
        ref: ref,
        channelId: widget.channelId,
        controller: widget.controller,
        apps: _apps,
        commands: _slashCommands,
        hasStagedFile: !_attachments.isEmpty,
        isMounted: () => mounted,
        clearError: () => setState(() => _commandError = null),
        onPosted: () => widget.onCommandPosted?.call(),
        replyToId: widget.replyToId,
        fail: _reportCommandError,
      );
    } finally {
      _commandRunning = false;
      if (mounted) setState(() {});
    }
    if (handled) return;
    await staging.sendReady(widget.onSend);
    if (mounted) {
      ref.read(messageSentSignalProvider.notifier).state++;
      setState(_mentionHelp.clear);
    }
  }

  void _dismissMentionHelp(String username) =>
      setState(() => _mentionHelp.dismiss(username));

  @override
  Widget build(BuildContext context) {
    final touch = AppTouchTargets.of(context);
    // In build because both sources are watched and can arrive late.
    _slashCommands = ref.watch(slashCommandProvider).valueOrNull ?? const [];
    _apps = ref.watch(appLaunchProvider).valueOrNull ?? const [];
    _botCommands =
        ref.watch(channelBotCommandsProvider(widget.channelId)).valueOrNull ??
        const [];
    _autocomplete.setSuggestions(
      watchAutocompleteSuggestions(
        ref,
        query: _autocomplete.query,
        channelId: widget.channelId,
        slashCommands: _slashCommands,
        apps: _apps,
        botCommands: _botCommands,
        gifSearch: _gifSearchEnabled,
      ),
    );
    _gifSearchEnabled =
        ref.watch(serverInfoProvider).valueOrNull?.gifSearchEnabled ?? false;
    _slowModeRemaining = ref.watch(
      slowModeRemainingSecondsProvider(widget.channelId),
    );

    // top: false because the composer only ever touches the bottom edge; the
    // padding self-cancels when the keyboard covers the home indicator.
    return SafeArea(
      top: false,
      child: Padding(
        // The same gutter the message rows and header use; a differently inset composer is visibly crooked.
        padding: EdgeInsets.fromLTRB(
          paneGutterOf(context),
          0,
          paneGutterOf(context),
          8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ComposerBotMentionHelpList(
              visibleUsernames: _mentionHelp.visible,
              allBotCommands: _botCommands,
              onDismiss: _dismissMentionHelp,
            ),
            ComposerBanners(
              attachmentError: _attachmentError,
              onDismissAttachmentError: () =>
                  setState(() => _attachmentError = null),
              commandError: _commandError,
              onDismissCommandError: () => setState(() => _commandError = null),
              overLimitBy: _stats.overBy,
              slowModeRemainingSeconds: _slowModeRemaining,
              stagedAttachments: _attachments.items,
              onRemoveAttachment: _attachments.remove,
              onRetryAttachment: _attachments.retry,
              isSpoiler: _attachments.isSpoiler,
              onToggleSpoiler: _attachments.toggleSpoiler,
            ),
            ComposerCodePasteOffer(paste: _codePaste),
            // Above the field, never below: that is the send row and keyboard.
            ComposerAutocomplete(
              suggestions: _autocomplete.suggestions,
              selected: _autocomplete.selected,
              onPick: _accept,
              onHover: _autocomplete.select,
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              child: TypingIndicator(channelId: widget.channelId),
            ),
            ComposerActionBar(
              touch: touch,
              controller: widget.controller,
              focusNode: _focus,
              channelId: widget.channelId,
              channelName: widget.channelName,
              hasText: _stats.hasText,
              canSend: _canSend,
              onSend: _send,
              onTyping: _onTyping,
              onOpenActions: _openActions,
              onPickFile: _actions.pickFileFromButton,
              onSendPressed: _sendFromButton,
              onInsertCode: _insertCodeFence,
              onPickEmoji: _pickEmoji,
              gifSearchEnabled: _gifSearchEnabled,
              onInsertEmoji: _insertPickedEmoji,
              onStageGif: _actions.stageGif,
              pickerController: _pickerController,
            ),
            ComposerPhotoStripSlot(
              channelId: widget.channelId,
              stage: _actions.stageAttachment,
              onBrowse: () => unawaited(
                _actions.pickAttachment(AttachmentSource.photoLibrary),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: MessageLengthCounter(length: _stats.charCount),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
