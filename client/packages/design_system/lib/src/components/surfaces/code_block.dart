// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Fenced code, and the short inline run used inside message text.
///
/// Neither widget parses or lexes code: a message is already-authored content
/// by the time it reaches the client, so syntax highlighting here is a pure
/// rendering step over a list of pre-classified spans, not a tokenizer.
library;

import 'package:flutter/material.dart';

import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';
import '../../touch_targets.dart';

/// The syntax role a span of code plays, matched one-to-one with
/// [AppCodeColors]'s five fields so a role can never be added on one side
/// without the other. [hidden] is the exception: a visible stand-in for a
/// character that would otherwise not show, drawn from the danger tokens.
enum AppCodeRole {
  keyword,
  string,
  number,
  comment,
  punctuation,
  plain,
  hidden,
}

/// One run of source text and the role it should be coloured as.
///
/// Whoever produces the span list (a fence-language highlighter, or a caller
/// that just wants one plain block) owns classification; this widget only
/// owns colour.
@immutable
class AppCodeSpan {
  const AppCodeSpan(this.text, [this.role = AppCodeRole.plain]);

  final String text;
  final AppCodeRole role;
}

/// One line of a fenced block, as a list of classified spans.
@immutable
class AppCodeLine {
  const AppCodeLine(this.spans);

  /// Convenience for a line that is entirely one role (or unclassified).
  AppCodeLine.plain(String text) : spans = [AppCodeSpan(text)];

  final List<AppCodeSpan> spans;
}

Color _roleColor(AppCodeRole role, AppTokens tokens, Color plain) {
  final code = tokens.code;
  return switch (role) {
    AppCodeRole.keyword => code.keyword,
    AppCodeRole.string => code.string,
    AppCodeRole.number => code.number,
    AppCodeRole.comment => code.comment,
    AppCodeRole.punctuation => code.punctuation,
    AppCodeRole.plain => plain,
    AppCodeRole.hidden => tokens.dangerText,
  };
}

/// A fenced code block: a raised monospace panel with a header row above a
/// hairline, one line per row so a caller can classify by line without
/// reflowing spans across line breaks.
///
/// The header renders unconditionally in the source (an always-present
/// language label plus an always-present `action` slot), so it is ported
/// unconditionally here too rather than hidden when both are empty: every
/// code block gets the same header band, language-less or not.
///
/// [action] is a generic slot, not a built-in copy button: the source hands
/// the caller a place to put whatever it wants (typically a copy affordance),
/// which keeps a clipboard dependency out of the design system package.
///
/// The body does not wrap: the source is a `<pre>` with `overflow: auto`, so
/// a long line scrolls horizontally instead of reflowing.
class AppCodeBlock extends StatefulWidget {
  const AppCodeBlock({
    super.key,
    required this.lines,
    this.language,
    this.action,
    this.notice,
    this.collapseAfterLines,
  });

  final List<AppCodeLine> lines;
  final String? language;
  final Widget? action;

  /// A band between the header and the body, for a warning the reader must
  /// see before acting on the block.
  final Widget? notice;

  /// When set and the block has more than this many lines, it renders
  /// collapsed to this many with a "show more"/"show less" toggle, the way a
  /// long paste is folded rather than eating the transcript. Null (the
  /// default) never collapses, so every existing caller renders as before.
  /// The header - language label and [action] (typically Run) - always shows,
  /// so a long block can be run without expanding it.
  final int? collapseAfterLines;

  @override
  State<AppCodeBlock> createState() => _AppCodeBlockState();
}

class _AppCodeBlockState extends State<AppCodeBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final threshold = widget.collapseAfterLines;
    final collapsible = threshold != null && widget.lines.length > threshold;
    final visible = collapsible && !_expanded
        ? widget.lines.take(threshold).toList(growable: false)
        : widget.lines;
    final hidden = collapsible ? widget.lines.length - threshold : 0;

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            // 6/10 are literal in the source, not on the --space-* grid.
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.language ?? '',
                    style: AppText.micro.copyWith(
                      fontFamily: AppFonts.mono,
                      color: tokens.textSecondary,
                      letterSpacing: 11 * AppTracking.mono,
                    ),
                  ),
                ),
                if (widget.action != null) widget.action!,
              ],
            ),
          ),
          if (widget.notice != null) widget.notice!,
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            // 10/12 are literal in the source, not on the --space-* grid.
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Text.rich(
              TextSpan(
                children: [
                  for (var i = 0; i < visible.length; i++) ...[
                    if (i > 0) const TextSpan(text: '\n'),
                    for (final span in visible[i].spans)
                      TextSpan(
                        text: span.text,
                        style: span.role == AppCodeRole.hidden
                            ? TextStyle(
                                color: tokens.dangerText,
                                fontWeight: FontWeight.w600,
                                backgroundColor: tokens.dangerBorder.withValues(
                                  alpha: 0.2,
                                ),
                              )
                            : TextStyle(
                                color: _roleColor(
                                  span.role,
                                  tokens,
                                  tokens.textPrimary,
                                ),
                              ),
                      ),
                  ],
                ],
              ),
              softWrap: false,
              // 13/1.6 are literal in the source; AppText.code (13.5/1.5) is
              // tuned for inline running text rather than a fenced block.
              style: TextStyle(
                fontFamily: AppFonts.mono,
                fontSize: 13,
                height: 1.6,
              ),
            ),
          ),
          if (collapsible)
            _CodeBlockToggle(
              expanded: _expanded,
              hidden: hidden,
              onTap: () => setState(() => _expanded = !_expanded),
            ),
        ],
      ),
    );
  }
}

/// The fold control below a collapsed block: a full-width hairline-topped bar
/// naming how many lines are hidden, so a long paste is scannable at a glance
/// and expandable in one tap.
class _CodeBlockToggle extends StatelessWidget {
  const _CodeBlockToggle({
    required this.expanded,
    required this.hidden,
    required this.onTap,
  });

  final bool expanded;
  final int hidden;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        constraints: BoxConstraints(
          minHeight: AppTouchTargets.of(context) ? AppSizes.rowTouch : 0,
        ),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: tokens.borderSubtle)),
        ),
        child: Text(
          expanded
              ? 'Show less'
              : 'Show $hidden more ${hidden == 1 ? 'line' : 'lines'}',
          style: AppText.micro.copyWith(
            fontFamily: AppFonts.mono,
            color: tokens.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// A short inline code run, for a `variable` or `command` mentioned inside
/// ordinary message text rather than a fenced block.
///
/// Raised rather than sunken, deliberately the opposite of [AppCodeBlock]:
/// an inline run sits inside a paragraph and needs to read as a small chip
/// lifted off the text around it, not as a recessed panel.
class AppInlineCode extends StatelessWidget {
  const AppInlineCode(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Text(
        text,
        style: AppText.code.copyWith(color: tokens.textPrimary),
      ),
    );
  }
}
