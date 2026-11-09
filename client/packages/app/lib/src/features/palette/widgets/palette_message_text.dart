// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message hit's text in a palette row: on at most [maxLines] lines, with its
/// emoji and mentions resolved the way the transcript does and the searched
/// words in bold.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../messages/widgets/message_text_spans.dart' show inlineTextSpans;
import 'palette_highlight.dart';

class PaletteMessageText extends StatefulWidget {
  const PaletteMessageText({
    super.key,
    required this.text,
    required this.terms,
    required this.maxLines,
    this.knownUsernames = const {},
    this.knownRoleNames = const {},
    this.customEmoji = const {},
  });

  final String text;

  /// What was searched for; every word of it is marked wherever it sits.
  final String terms;
  final int maxLines;

  /// See `MessageBody`: what a hit's mentions and emoji are resolved against.
  final Set<String> knownUsernames;
  final Set<String> knownRoleNames;
  final Map<String, String> customEmoji;

  @override
  State<PaletteMessageText> createState() => _PaletteMessageTextState();
}

class _PaletteMessageTextState extends State<PaletteMessageText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final style = AppText.ui.copyWith(color: tokens.textPrimary);
    return Text.rich(
      TextSpan(
        style: style,
        children: paletteHighlightInline(
          inlineTextSpans(
            paletteSnippet(widget.text, widget.terms),
            customEmoji: widget.customEmoji,
            ambientStyle: style,
            linkColor: tokens.accent,
            recognizers: _recognizers,
            knownUsernames: widget.knownUsernames,
            knownRoleNames: widget.knownRoleNames,
          ),
          widget.terms,
        ),
      ),
      maxLines: widget.maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}
