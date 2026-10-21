// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The text box a canvas note is typed into, carrying the composer's input
/// features: `@` member autocomplete, `:` emoji autocomplete and shortcode
/// conversion, markdown shortcuts, list continuation and an emoji picker.
///
/// Every piece is the composer's own widget or pure function; this file only
/// wires them to a field that has no send row.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/admin_providers.dart';
import '../../../widgets/text_insert.dart';
import '../../composer/widgets/composer_autocomplete.dart';
import '../../composer/widgets/composer_autocomplete_items.dart';
import '../../composer/widgets/composer_autocomplete_query.dart';
import '../../composer/widgets/composer_list_keys.dart';
import '../../composer/widgets/composer_markdown_shortcuts.dart';
import '../../composer/widgets/composer_shortcodes.dart';
import '../../emoji/widgets/emoji_picker_sheets.dart';
import '../../members/providers/member_presence.dart' show membersProvider;
import 'canvas_note_limits.dart';

class CanvasNoteField extends ConsumerStatefulWidget {
  const CanvasNoteField({
    super.key,
    required this.controller,
    required this.focusNode,
    this.onSave,
    this.onCancel,
    this.hintText,
    this.minLines = 3,
    this.maxLines = 8,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// Ctrl or Cmd plus Enter; plain Enter is a new line.
  final VoidCallback? onSave;
  final VoidCallback? onCancel;
  final String? hintText;
  final int minLines;
  final int maxLines;

  @override
  ConsumerState<CanvasNoteField> createState() => _CanvasNoteFieldState();
}

class _CanvasNoteFieldState extends ConsumerState<CanvasNoteField> {
  final _listKeys = ComposerListKeys();
  AutocompleteQuery? _query;
  int _selected = 0;
  bool _full = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    // The field's own node: text editing handles the arrows above it, so an ancestor would run too late.
    widget.focusNode.onKeyEvent = _onKey;
  }

  @override
  void didUpdateWidget(covariant CanvasNoteField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.onKeyEvent = null;
      widget.focusNode.onKeyEvent = _onKey;
    }
  }

  @override
  void dispose() {
    widget.focusNode.onKeyEvent = null;
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (_full && _fits(widget.controller.text)) setState(() => _full = false);
    final query = _supportedQuery(
      autocompleteQueryAt(
        widget.controller.text,
        widget.controller.selection.baseOffset,
      ),
    );
    if (query == _query) return;
    setState(() {
      _query = query;
      _selected = 0;
    });
  }

  /// Slash commands run on send, which a note never does.
  AutocompleteQuery? _supportedQuery(AutocompleteQuery? query) {
    if (query == null) return null;
    return switch (query.kind) {
      AutocompleteKind.mention || AutocompleteKind.emoji => query,
      AutocompleteKind.command ||
      AutocompleteKind.botCommand ||
      AutocompleteKind.botOption => null,
    };
  }

  List<AutocompleteSuggestion> _suggestions() {
    final query = _query;
    if (query == null) return const [];
    return autocompleteSuggestions(
      query: query,
      custom: ref.watch(customEmojiProvider).valueOrNull ?? const [],
      members: ref.watch(membersProvider).valueOrNull ?? const [],
    );
  }

  void _accept(AutocompleteSuggestion suggestion) {
    final query = _query;
    if (query == null) return;
    final text = widget.controller.text;
    _setIfFits(
      TextEditingValue(
        text: text.replaceRange(query.start, query.end, suggestion.insert),
        selection: TextSelection.collapsed(
          offset: query.start + suggestion.insert.length,
        ),
      ),
    );
    widget.focusNode.requestFocus();
  }

  bool _fits(String text) => noteWireBytes(text) <= maxNoteTextBytes;

  /// Programmatic edits bypass the field's formatter, so they meet the same limit here.
  void _setIfFits(TextEditingValue value) {
    if (_fits(value.text)) {
      widget.controller.value = value;
    } else {
      _markFull();
    }
  }

  void _markFull() {
    if (!_full) setState(() => _full = true);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final suggestions = _suggestions();
    if (_query != null && suggestions.isNotEmpty) {
      final handled = _onAutocompleteKey(event, suggestions);
      if (handled != KeyEventResult.ignored) return handled;
    }
    // An open IME composition owns Enter: it confirms the candidate.
    if (widget.controller.value.composing.isValid) {
      return KeyEventResult.ignored;
    }
    if (_isPlainEnter(event)) {
      _setIfFits(applyListAwareEnter(widget.controller.value));
      return KeyEventResult.handled;
    }
    return _listKeys.handle(event, widget.controller);
  }

  bool _isPlainEnter(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    return event.logicalKey == LogicalKeyboardKey.enter &&
        !keyboard.isControlPressed &&
        !keyboard.isMetaPressed;
  }

  KeyEventResult _onAutocompleteKey(
    KeyEvent event,
    List<AutocompleteSuggestion> suggestions,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      setState(() => _query = null);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _selected = (_selected + 1) % suggestions.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(
        () => _selected =
            (_selected - 1 + suggestions.length) % suggestions.length,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab || key == LogicalKeyboardKey.enter) {
      final keyboard = HardwareKeyboard.instance;
      if (keyboard.isControlPressed || keyboard.isMetaPressed) {
        return KeyEventResult.ignored;
      }
      _accept(suggestions[_selected.clamp(0, suggestions.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _pickEmoji() => unawaited(
    showEmojiPickerSheet(
      context,
      onSelect: (emoji) {
        widget.focusNode.requestFocus();
        final before = widget.controller.value;
        insertAtSelection(widget.controller, emoji);
        if (!_fits(widget.controller.text)) {
          widget.controller.value = before;
          _markFull();
        }
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final suggestions = _suggestions();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ComposerAutocomplete(
          suggestions: suggestions,
          selected: _selected,
          onPick: _accept,
          onHover: (i) => setState(() => _selected = i),
        ),
        ComposerShortcodes(
          controller: widget.controller,
          child: CallbackShortcuts(
            bindings: {
              ...emphasisShortcuts(widget.controller),
              if (widget.onSave != null) ...{
                const SingleActivator(LogicalKeyboardKey.enter, control: true):
                    widget.onSave!,
                const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                    widget.onSave!,
              },
              if (widget.onCancel != null)
                const SingleActivator(LogicalKeyboardKey.escape):
                    widget.onCancel!,
            },
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  // Named outside the field too: its hint leaves the accessible name once there is text.
                  child: Semantics(
                    label: widget.hintText,
                    child: TextField(
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      minLines: widget.minLines,
                      maxLines: widget.maxLines,
                      keyboardType: TextInputType.multiline,
                      inputFormatters: [
                        NoteByteLimitFormatter(onRefused: _markFull),
                      ],
                      style: AppText.body.copyWith(color: tokens.textPrimary),
                      cursorColor: tokens.accent,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        hintText: widget.hintText,
                      ),
                    ),
                  ),
                ),
                AppIconButton(
                  icon: AppIcons.smile,
                  semanticLabel: 'Insert emoji',
                  tooltip: 'Insert emoji',
                  onPressed: _pickEmoji,
                ),
              ],
            ),
          ),
        ),
        if (_full)
          Text(
            'This note is full.',
            style: AppText.caption.copyWith(color: tokens.dangerText),
          ),
      ],
    );
  }
}
