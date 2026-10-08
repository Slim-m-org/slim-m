// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A poll's question or option label: inline formatting and custom emoji
/// shortcodes like a message, but never block markdown.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/emoji_catalog_provider.dart';
import 'message_text.dart';

class PollText extends ConsumerStatefulWidget {
  const PollText(this.text, {super.key, required this.style, this.maxLines});

  final String text;

  /// Colour comes from [AppTokens.textPrimary]; this carries size and weight.
  final TextStyle style;
  final int? maxLines;

  @override
  ConsumerState<PollText> createState() => _PollTextState();
}

class _PollTextState extends ConsumerState<PollText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final style = widget.style.copyWith(color: tokens.textPrimary);
    return Text.rich(
      TextSpan(
        style: style,
        children: inlineTextSpans(
          widget.text,
          customEmoji: ref.watch(customEmojiIndexProvider),
          ambientStyle: style,
          linkColor: tokens.accent,
          recognizers: _recognizers,
        ),
      ),
      maxLines: widget.maxLines,
      overflow: widget.maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}
