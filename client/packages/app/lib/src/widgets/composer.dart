// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The message composer: a bordered card, its affordances, and the hint row
/// beneath it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Unaliased: `uploadAttachment` is an extension method, visible only where imported.
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../permissions.dart';
import '../providers/admin_providers.dart';
import '../providers/bot_commands.dart';
import '../providers/channel_permissions.dart';
import '../providers/composer_attachment_drop.dart';
import '../providers/composer_focus.dart';
import '../providers/member_presence.dart' show membersProvider;
import '../providers/message_actions.dart' show lastOwnMessageInChannel;
import '../providers/message_editing.dart';
import '../providers/app_launch.dart';
import '../providers/providers.dart';
import '../routing/breakpoints.dart';
import '../providers/slash_command.dart';
import '../providers/slow_mode_controller.dart';
import '../providers/typing_controller.dart';
import 'app_launcher_sheet.dart';
import 'attachment_picker.dart';
import 'channel_rail_frame.dart' show serverInfoProvider;
import 'composer_action_bar.dart';
import 'composer_attachments.dart';
import 'composer_autocomplete.dart';
import 'composer_autocomplete_items.dart';
import 'composer_autocomplete_query.dart';
import 'composer_bot_mention_help.dart';
import 'composer_bot_mentions.dart';
import 'composer_clipboard_image.dart';
import 'composer_clipboard_paste.dart';
import 'composer_drop_registration.dart';
import 'composer_extras.dart';
import 'composer_list_keys.dart';
import 'composer_photo_strip.dart';
import 'composer_slash.dart';
import 'emoji_picker.dart';
import 'gif_picker.dart';
import 'poll_composer_sheet.dart';
import 'text_insert.dart';
import 'typing_indicator.dart';

class Composer extends ConsumerStatefulWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.channelId,
    required this.channelName,
    required this.onSend,
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
  final Future<void> Function(List<String> attachmentIds) onSend;

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
  /// Two flags, one purpose each. [_hasText] drives the placeholder and is
  /// deliberately untrimmed, so typed spaces hide it; [_hasSendableText] is
  /// trimmed, because the send path drops whitespace-only text.
  bool _hasText = false;
  bool _hasSendableText = false;
  late AttachmentStagingController _attachments;

  /// Shown inline above the action bar: a picker that would not open, or a
  /// clipboard paste that failed. Both are "could not get you an
  /// attachment", the one band `ComposerBanners` reserves for it.
  String? _attachmentError;
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);
  final ComposerListKeys _listKeys = ComposerListKeys();

  /// The composed text's own length and how far over [kMessageMaxChars] it
  /// sits, if at all. Tracked alongside [_hasText] rather than read fresh in
  /// [build], so [_handleChange] can decide when a rebuild is worth it.
  int _charCount = 0;
  int? _overBy;

  /// `Version.gifSearchEnabled`, refreshed in [build]; see [_openActions].
  bool _gifSearchEnabled = false;

  /// Seconds left before slow mode allows another send, refreshed in
  /// [build] from [slowModeRemainingSecondsProvider]; see [_canSend].
  int _slowModeRemaining = 0;

  /// Captured once rather than read from `ref` in [dispose]: by then
  /// Riverpod has already detached this element's `ref`, and reading it
  /// throws "Cannot use ref after the widget was disposed". Every write to
  /// it, from [initState] and [dispose] alike, goes through a post-frame
  /// callback rather than running synchronously: either method can be
  /// reached as part of the very build/frame that swaps this widget out
  /// (for `BlockedDmNotice` among others), and a provider write from there
  /// is a build-time mutation, which Riverpod rejects outside tests too.
  StateController<FocusNode?>? _focusRegistry;

  /// Keyed by [Composer.channelId]; `channel_attachment_drop_zone.dart`
  /// reaches this composer's staging through it.
  final _drop = ComposerDropRegistration();

  /// The trigger the caret is inside, and which of its offers is current.
  ///
  /// Held here rather than in the panel because all three act on the text
  /// field this widget owns: the keys are intercepted on its focus node, and
  /// accepting rewrites its value.
  AutocompleteQuery? _query;
  List<AutocompleteSuggestion> _suggestions = const [];
  List<SlashCommand> _slashCommands = const [];
  List<App> _apps = const [];
  List<ChannelBotCommand> _botCommands = const [];

  /// Bot usernames whose mention-help card has been shown or dismissed this
  /// message, so retyping the same `@mention` never re-triggers it.
  final Set<String> _mentionHelpSeen = {};
  final List<String> _visibleMentionHelp = [];
  String? _commandError;

  /// True while a command awaits its result, so a second send cannot rerun it.
  bool _commandRunning = false;
  int _selected = 0;

  /// A staged file is sendable on its own: a photo needs no caption, and the
  /// server accepts an empty body precisely when attachments ride along.
  /// Blocked while anything staged is still uploading or has failed, or a
  /// send would go out missing whatever has not resolved to an id yet.
  /// Also blocked over the character limit, so a doomed request never
  /// reaches the wire at all; see [ComposerBanners]'s `overLimitBy` band for
  /// where that refusal is explained.
  bool get _canSend =>
      !_commandRunning &&
      (_hasSendableText || !_attachments.isEmpty) &&
      !_attachments.hasBlockingAttachment &&
      _overBy == null &&
      _slowModeRemaining <= 0;

  @override
  void initState() {
    super.initState();
    _attachments = ref.read(attachmentStagingProvider(widget.channelId))
      ..addListener(_handleAttachmentsChange);
    _hasText = widget.controller.text.isNotEmpty;
    _hasSendableText = widget.controller.text.trim().isNotEmpty;
    _charCount = widget.controller.text.runes.length;
    _overBy = messageLengthOverage(_charCount);
    widget.controller.addListener(_handleChange);
    _focus.addListener(_handleFocusChange);
    // See [_focusRegistry]'s doc comment for why this waits a frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final registry = ref.read(composerFocusNodeProvider.notifier);
      registry.state = _focus;
      _focusRegistry = registry;
    });
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
        _mentionHelpSeen.clear();
        _visibleMentionHelp.clear();
        _selected = 0;
      });
      _rebindDropTarget();
    }
  }

  void _rebindDropTarget() => _drop.bind(
    ref: ref,
    channelId: widget.channelId,
    target: () => ComposerAttachmentDropTarget(
      stage: _stageAttachment,
      setError: _setAttachmentError,
    ),
    isMounted: () => mounted,
  );

  @override
  void dispose() {
    // Guards mounted too: the whole container can be gone by this frame.
    final registry = _focusRegistry;
    final focus = _focus;
    _drop.release();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (registry != null && registry.mounted && registry.state == focus) {
        registry.state = null;
      }
    });
    widget.controller.removeListener(_handleChange);
    _focus.removeListener(_handleFocusChange);
    widget.clipboardPasteStop(_handlePastedImage);
    _focus.dispose();
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

  /// Ctrl+V only reaches an image while this field genuinely has focus: the
  /// seam behind [Composer.clipboardPasteStart] is a single global listener
  /// (see `composer_clipboard_image_web.dart`), so it has to be handed off
  /// on every focus change rather than left running for the widget's whole
  /// life.
  void _handleFocusChange() {
    if (_focus.hasFocus) {
      widget.clipboardPasteStart(_handlePastedImage);
    } else {
      widget.clipboardPasteStop(_handlePastedImage);
    }
  }

  void _handleChange() {
    final hasText = widget.controller.text.isNotEmpty;
    final sendable = widget.controller.text.trim().isNotEmpty;
    final charCount = widget.controller.text.runes.length;
    final overBy = messageLengthOverage(charCount);
    final query = autocompleteQueryAt(
      widget.controller.text,
      widget.controller.selection.baseOffset,
    );
    // True while the counter is or was on screen, so its own value keeps redrawing.
    final countMatters =
        messageCounterVisible(charCount) || messageCounterVisible(_charCount);
    final changed =
        hasText != _hasText ||
        sendable != _hasSendableText ||
        query != _query ||
        overBy != _overBy ||
        (countMatters && charCount != _charCount);
    final newlyMentioned = mentionedBotUsernames(
      widget.controller.text,
      _botCommands.map((c) => c.botUsername),
    ).difference(_mentionHelpSeen).toList();
    if (!changed && newlyMentioned.isEmpty) return;
    setState(() {
      _hasText = hasText;
      _hasSendableText = sendable;
      _charCount = charCount;
      _overBy = overBy;
      if (query != _query) {
        _query = query;
        // Back to row one, so Enter takes whatever now ranks first.
        _selected = 0;
      }
      if (newlyMentioned.isNotEmpty) {
        _mentionHelpSeen.addAll(newlyMentioned);
        _visibleMentionHelp.addAll(newlyMentioned);
      }
    });
  }

  /// Rebuilt during build rather than stored, since the member list and the
  /// Space's emoji are both watched providers and either can arrive late.
  List<AutocompleteSuggestion> _buildSuggestions() {
    final query = _query;
    if (query == null) return const [];
    return autocompleteSuggestions(
      query: query,
      custom: ref.watch(customEmojiProvider).valueOrNull ?? const [],
      members: ref.watch(membersProvider).valueOrNull ?? const [],
      selfId: ref.watch(meProvider).valueOrNull?.id,
      canMentionEveryone: ref
          .watch(myChannelPermissionsProvider(widget.channelId))
          .hasPermission(Perm.mentionEveryone),
      slashCommands: _slashCommands,
      apps: _apps,
      botCommands: _botCommands,
    );
  }

  void _dismissAutocomplete() {
    if (_query == null) return;
    setState(() {
      _query = null;
      _selected = 0;
    });
  }

  /// Replaces the trigger span with what was chosen and closes the list.
  void _accept(AutocompleteSuggestion suggestion) {
    final query = _query;
    if (query == null) return;
    final text = widget.controller.text;
    widget.controller.value = TextEditingValue(
      text: text.replaceRange(query.start, query.end, suggestion.insert),
      selection: TextSelection.collapsed(
        offset: query.start + suggestion.insert.length,
      ),
    );
    _focus.requestFocus();
    _dismissAutocomplete();
  }

  /// Opens the caller's own most recent message in this channel for inline
  /// editing - see [_onKey]. `mounted` is checked after each await rather
  /// than inside [lastOwnMessageInChannel] itself, which takes no `ref` and
  /// so has no way to know whether this widget is still around by the time
  /// its snapshot resolves.
  ///
  /// [meProvider] is awaited by its own `.future` rather than read
  /// synchronously: nothing else in the composer keeps it warm, so a cold
  /// first read here would otherwise catch it mid-`AsyncLoading` and find no
  /// id at all.
  Future<void> _editLastOwnMessage() async {
    final store = await ref.read(storeProvider.future);
    if (!mounted) return;
    final myId = await ref
        .read(meProvider.future)
        .then<String?>((me) => me.id, onError: (Object _) => null);
    if (!mounted) return;
    final message = await lastOwnMessageInChannel(
      store,
      widget.channelId,
      myId,
    );
    if (!mounted || message == null) return;
    ref.read(editingMessageIdProvider(widget.channelId).notifier).state =
        message.id;
  }

  /// Intercepts the keys the list needs, on the field's own focus node.
  ///
  /// It has to be this node rather than an ancestor: text editing handles the
  /// arrows through `Actions` installed above the field, so a handler higher
  /// up would run after the caret had already moved.
  ///
  /// The paste check sits above the autocomplete guard on purpose, since it
  /// has to run whether or not a mention list happens to be open, and it
  /// never returns `handled`, so Flutter's own text paste is untouched.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (isClipboardPasteChord(event)) {
      unawaited(
        pasteClipboardImageFromKeystroke(_stageAttachment, _setAttachmentError),
      );
    }
    // Up in an empty composer edits the caller's last message; with text typed it must move the caret as normal instead.
    if (event is KeyDownEvent &&
        widget.controller.text.isEmpty &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      unawaited(_editLastOwnMessage());
      return KeyEventResult.handled;
    }
    if (_query == null || _suggestions.isEmpty) {
      return _listKeys.handle(event, widget.controller);
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _dismissAutocomplete();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _selected = (_selected + 1) % _suggestions.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(
        () => _selected =
            (_selected - 1 + _suggestions.length) % _suggestions.length,
      );
      return KeyEventResult.handled;
    }
    // Both accept; Enter would otherwise send the half-typed trigger.
    if (key == LogicalKeyboardKey.tab || key == LogicalKeyboardKey.enter) {
      final keyboard = HardwareKeyboard.instance;
      // A held modifier is a global shortcut (Ctrl/Cmd+Tab cycles channels), not an accept.
      if (keyboard.isShiftPressed ||
          keyboard.isControlPressed ||
          keyboard.isMetaPressed) {
        return KeyEventResult.ignored;
      }
      _accept(_suggestions[_selected]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Replaces the current selection (or inserts at the caret) and leaves the
  /// caret [caretOffset] characters after the start of what was inserted.
  void _insert(String text, {int? caretOffset}) =>
      insertAtSelection(widget.controller, text, caretOffset: caretOffset);

  void _insertCodeFence() => _insert('``', caretOffset: 1);

  /// Touch density only: the Space's own emoji; native ones come from the
  /// keyboard. Desktop width reaches `ComposerPickerButton`'s panel instead.
  void _pickEmoji() =>
      unawaited(showSpaceEmojiSheet(context, onSelect: _insertPickedEmoji));

  void _insertPickedEmoji(String emoji) {
    _focus.requestFocus();
    _insert(emoji);
  }

  void _openActions() => unawaited(
    showComposerActionsSheet(
      context,
      onPhotoLibrary: () => openPhotoStripOr(
        context,
        ref,
        widget.channelId,
        fallback: () =>
            unawaited(_pickAttachment(AttachmentSource.photoLibrary)),
      ),
      onBrowseFiles: () =>
          unawaited(_pickAttachment(AttachmentSource.fileBrowser)),
      canPasteImage: composerClipboardPasteAvailable(),
      onPasteImage: () =>
          unawaited(pasteClipboardImage(_stageAttachment, _setAttachmentError)),
      onPoll: () => showPollComposerSheet(context, widget.channelId),
      onCode: _insertCodeFence,
      onGif: _gifSearchEnabled ? _pickGif : null,
      // Only when there is something to launch; an empty menu entry would dead-end.
      onApps: _apps.isEmpty
          ? null
          : () => unawaited(
              showAppLauncherSheet(
                context,
                ref,
                widget.channelId,
                onError: _reportCommandError,
              ),
            ),
    ),
  );

  /// Touch density only: the flow is `gif_picker.dart`'s `pickGif`; desktop
  /// reaches [_stageGif] through the same anchored panel as [_pickEmoji].
  void _pickGif() => unawaited(
    pickGif(
      context: context,
      ref: ref,
      attachments: _attachments,
      onError: _setAttachmentError,
    ),
  );

  Future<void> _stageGif(Attachment attachment) => stageGif(
    context: context,
    ref: ref,
    attachments: _attachments,
    onError: _setAttachmentError,
    attachment: attachment,
  );

  /// Re-focuses first so a soft keyboard stays up across the send, matching
  /// what the field's own submit action does.
  void _sendFromButton() {
    _focus.requestFocus();
    unawaited(_send());
  }

  /// Desktop has no photo/files split, so one tap opens the document picker.
  void _pickFileFromButton() =>
      unawaited(_pickAttachment(AttachmentSource.fileBrowser));

  /// Cleared up front so a successful retry leaves no stale failure on screen.
  Future<void> _pickAttachment(AttachmentSource source) {
    _setAttachmentError(null);
    return runAttachmentPick(
      pick: ref.read(attachmentPickerProvider(source)),
      focus: _focus,
      isMounted: () => mounted,
      onPickerFailed: () =>
          _setAttachmentError('Could not open the file picker.'),
      stage: _stageAttachment,
    );
  }

  /// Stages bytes from any source, visible at once while the upload runs in
  /// the background; the one way onto the send path.
  Future<void> _stageAttachment(Uint8List bytes, String filename) =>
      _attachments.stage(bytes, filename);

  /// A pasted image takes the same staging path as a picked file.
  void _handlePastedImage(Uint8List bytes, String filename) =>
      unawaited(_stageAttachment(bytes, filename));

  void _setAttachmentError(String? message) {
    if (mounted) setState(() => _attachmentError = message);
  }

  void _removeAttachment(String localId) => _attachments.remove(localId);

  void _retryAttachment(String localId) => _attachments.retry(localId);

  void _onTyping(String _) => ref
      .read(typingControllerProvider(widget.channelId).notifier)
      .notifyTyping();

  void _reportCommandError(String message) {
    if (mounted) setState(() => _commandError = message);
  }

  /// A `/command` for a module runs it and posts its output; anything else is
  /// an ordinary send. See `composer_slash.dart` for the run itself.
  Future<void> _send() async {
    if (!_canSend) return;
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
        post: () => widget.onSend(const []),
        fail: _reportCommandError,
      );
    } finally {
      _commandRunning = false;
      if (mounted) setState(() {});
    }
    if (handled) return;
    await staging.sendReady(widget.onSend);
    if (mounted) {
      setState(() {
        _mentionHelpSeen.clear();
        _visibleMentionHelp.clear();
      });
    }
  }

  void _dismissMentionHelp(String username) =>
      setState(() => _visibleMentionHelp.remove(username));

  @override
  Widget build(BuildContext context) {
    final touch = AppTouchTargets.of(context);
    // In build because both sources are watched and can arrive late.
    _slashCommands = ref.watch(slashCommandProvider).valueOrNull ?? const [];
    _apps = ref.watch(appLaunchProvider).valueOrNull ?? const [];
    _botCommands =
        ref.watch(channelBotCommandsProvider(widget.channelId)).valueOrNull ??
        const [];
    _suggestions = _buildSuggestions();
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
              visibleUsernames: _visibleMentionHelp,
              allBotCommands: _botCommands,
              onDismiss: _dismissMentionHelp,
            ),
            ComposerBanners(
              attachmentError: _attachmentError,
              onDismissAttachmentError: () =>
                  setState(() => _attachmentError = null),
              commandError: _commandError,
              onDismissCommandError: () => setState(() => _commandError = null),
              overLimitBy: _overBy,
              slowModeRemainingSeconds: _slowModeRemaining,
              stagedAttachments: _attachments.items,
              onRemoveAttachment: _removeAttachment,
              onRetryAttachment: _retryAttachment,
            ),
            // Above the field, never below: that is the send row and keyboard.
            ComposerAutocomplete(
              suggestions: _suggestions,
              selected: _selected,
              onPick: _accept,
              onHover: (i) => setState(() => _selected = i),
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
              hasText: _hasText,
              canSend: _canSend,
              onSend: _send,
              onTyping: _onTyping,
              onOpenActions: _openActions,
              onPickFile: _pickFileFromButton,
              onSendPressed: _sendFromButton,
              onInsertCode: _insertCodeFence,
              onPickEmoji: _pickEmoji,
              gifSearchEnabled: _gifSearchEnabled,
              onInsertEmoji: _insertPickedEmoji,
              onStageGif: _stageGif,
            ),
            ComposerPhotoStripSlot(
              channelId: widget.channelId,
              stage: _stageAttachment,
              onBrowse: () =>
                  unawaited(_pickAttachment(AttachmentSource.photoLibrary)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: MessageLengthCounter(length: _charCount),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
