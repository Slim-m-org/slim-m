// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Rendering a message body: fenced code, headings, quotes, lists, inline
/// markdown, mentions, and the deployment's own `:shortcode:` emoji.
///
/// Inline nesting (`**bold with *italic* inside**`) comes from
/// `message_inline.dart`'s recursive-descent parser; this file walks its tree
/// into `InlineSpan`s and is where the leaf tokens that need data (mention,
/// role mention, emoji) get resolved against what this message actually has.
///
/// There is no mention *highlighting* protocol on the wire; deciding whether
/// an `@name` token becomes a chip is a client-side judgement, applied to an
/// `@name` that matches a real, currently-known member's username, or to the
/// two reserved words `@everyone`/`@here` (`push::recipients` in
/// `crates/slimm-server`, gated there on `Perm.mentionEveryone` - rendering a
/// chip here does not imply the sender actually held it, only that the word
/// is one the server recognises). An `@` that matches neither renders as
/// plain text, so nothing here invents a person who is not real. An
/// `@[Role Name]` token follows the identical rule against a currently-known
/// role name instead - see [_isRenderableRole].
///
/// A `:shortcode:` resolves the same way and for the same reason: only a name
/// the deployment actually holds becomes an image, and everything else stays
/// the text that was typed.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../external_link.dart';
import '../message_link.dart';
import '../providers/providers.dart';
import 'app_snackbar.dart';
import 'channel_rail.dart' show selectedChannelId;
import 'custom_emoji_image.dart';
import 'message_jump.dart' show jumpToMessage;
import 'message_code_block_runner.dart';
import 'message_fences.dart';
import 'message_inline.dart';
import 'message_markdown_blocks.dart';
import 'message_spoiler.dart';

part 'message_text_spans.dart';

/// One line tall: [AppText.body] is 15px at a 1.45 line height, so an inline
/// emoji is that product rather than a pixel value chosen to look right.
/// [CustomEmojiImage] defaults to the picker's 20; running text is not the
/// picker, so it says what it needs.
final double _emojiSize = AppText.body.fontSize! * AppText.body.height!;

/// A message body: fenced code blocks rendered through [AppCodeBlock], and
/// everything else split into headings, quotes, lists and paragraphs, each
/// carrying its own nested inline markdown. [knownUsernames] should be
/// lower-cased; pass an empty set while the member list has not loaded rather
/// than guessing.
class MessageBody extends StatelessWidget {
  const MessageBody({
    super.key,
    required this.content,
    required this.knownUsernames,
    this.messageId,
    this.knownRoleNames = const {},
    this.customEmoji = const {},
    this.dim = false,
    this.announceSending = false,
    this.trailing,
  });

  final String content;

  /// A short note set after the last word of the body, as part of the same
  /// line of text (the edited marker). A body that does not end in running
  /// text (a code block last) shows it on a line of its own instead.
  final Widget? trailing;

  /// The message these blocks belong to, so a fenced code block's Run result
  /// is shared against `(messageId, block index)` and seen by everyone. Null
  /// where there is no stable message to key against (a forwarded body,
  /// tests), which leaves a run ephemeral and per-viewer, as it was before.
  final String? messageId;
  final Set<String> knownUsernames;

  /// Lower-cased role name to render an `@[Role Name]` token as a chip.
  /// Defaulted to empty (every caller that has not been given a member
  /// roster to derive it from) rather than required, so a role mention
  /// simply renders as plain text until one is supplied - the same fallback
  /// [knownUsernames] would want but cannot have, since that one is already
  /// load-bearing for every existing caller and test.
  final Set<String> knownRoleNames;

  /// Lower-cased emoji name to emoji id, from `customEmojiIndexProvider`.
  /// Defaulted rather than required so a caller with no emoji to resolve
  /// (and every existing test) renders shortcodes as the plain text they are.
  final Map<String, String> customEmoji;

  /// True for a pending or failed send, which reads as provisional rather
  /// than delivered.
  final bool dim;

  /// True only while still sending: dims the same way [dim] does, and also
  /// gives the body a "Sending" semantics label, since [dim] on its own is a
  /// sighted-only cue - a screen reader reading this body's text got nothing
  /// distinguishing it from an already-delivered message. Deliberately not
  /// merged with [dim] itself: a caller dimming for some other reason
  /// (there is none today) must not also announce a delivery state that
  /// is not true.
  final bool announceSending;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    // Provisional-to-delivered ink lerps rather than snapping on confirm.
    final body = TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: dim ? 1.0 : 0.0),
      duration: AppMotion.reduced(context, AppMotion.base),
      curve: AppMotion.entrance,
      builder: (context, t, _) {
        final baseColor = Color.lerp(
          tokens.textPrimary,
          tokens.textSecondary,
          t,
        )!;

        final widgets = <Widget>[];
        // Counts only fenced blocks, so a block's index (the shared-run key) is stable regardless of the text around it.
        var codeBlockIndex = 0;
        final blocks = splitMessageBlocks(content);
        var trailed = false;
        for (final block in blocks) {
          switch (block) {
            case TextBlock(:final text):
              final mds = splitMarkdownBlocks(text);
              for (final md in mds) {
                final last =
                    identical(block, blocks.last) && identical(md, mds.last);
                trailed = trailed || (last && trailing != null);
                widgets.add(
                  _buildMarkdownBlock(
                    md,
                    knownUsernames: knownUsernames,
                    knownRoleNames: knownRoleNames,
                    customEmoji: customEmoji,
                    color: baseColor,
                    trailing: last ? trailing : null,
                  ),
                );
              }
            case CodeBlock(:final language, :final code):
              widgets.add(
                MessageCodeBlockRunner(
                  language: language,
                  code: code,
                  messageId: messageId,
                  blockIndex: codeBlockIndex++,
                ),
              );
          }
        }

        if (trailing != null && !trailed) {
          widgets.add(Padding(padding: _trailingLineInset, child: trailing));
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < widgets.length; i++) ...[
              if (i > 0) const SizedBox(height: AppSpacing.s4),
              widgets[i],
            ],
          ],
        );
      },
    );

    // Its own container node: this body's several blocks already carry their own semantics, so a non-container label would have nowhere unambiguous to merge into.
    return announceSending
        ? Semantics(container: true, label: 'Sending', child: body)
        : body;
  }
}

/// A sub-grid optical gap above a trailing note that has to sit on its own line.
const _trailingLineInset = EdgeInsets.only(top: 2);

/// Picks the type step and rendering shell for one [MarkdownBlock], then
/// hands its text to [_MessageTextRun] for inline parsing. Only headings
/// change the type style, from the scale's own three largest steps, never an
/// invented size.
Widget _buildMarkdownBlock(
  MarkdownBlock block, {
  required Set<String> knownUsernames,
  required Set<String> knownRoleNames,
  required Map<String, String> customEmoji,
  required Color color,
  Widget? trailing,
}) {
  switch (block) {
    case ParagraphBlock(:final text):
      return _MessageTextRun(
        text: text,
        knownUsernames: knownUsernames,
        knownRoleNames: knownRoleNames,
        customEmoji: customEmoji,
        color: color,
        trailing: trailing,
      );
    case HeadingBlock(:final level, :final text):
      final style = switch (level) {
        1 => AppText.title,
        2 => AppText.heading,
        _ => AppText.body,
      }.copyWith(fontWeight: AppWeights.semi);
      return _MessageTextRun(
        text: text,
        knownUsernames: knownUsernames,
        knownRoleNames: knownRoleNames,
        customEmoji: customEmoji,
        color: color,
        baseStyle: style,
        trailing: trailing,
      );
    case QuoteBlock(:final text):
      return MarkdownQuote(
        child: _MessageTextRun(
          text: text,
          knownUsernames: knownUsernames,
          knownRoleNames: knownRoleNames,
          customEmoji: customEmoji,
          color: color,
          trailing: trailing,
        ),
      );
    case ListBlock(:final items):
      return MarkdownList(
        items: items,
        children: [
          for (final item in items)
            _MessageTextRun(
              text: item.text,
              knownUsernames: knownUsernames,
              knownRoleNames: knownRoleNames,
              customEmoji: customEmoji,
              color: color,
              trailing: identical(item, items.last) ? trailing : null,
            ),
        ],
      );
  }
}

/// One run of text with inline markdown, mentions and custom emoji picked
/// out. [baseStyle] carries size and weight; [color] is applied on top of it
/// so dimmed (pending/failed) messages still work at any heading level.
class _MessageTextRun extends ConsumerStatefulWidget {
  const _MessageTextRun({
    required this.text,
    required this.knownUsernames,
    required this.knownRoleNames,
    required this.customEmoji,
    required this.color,
    this.baseStyle = AppText.body,
    this.trailing,
  });

  final Widget? trailing;
  final String text;
  final Set<String> knownUsernames;
  final Set<String> knownRoleNames;
  final Map<String, String> customEmoji;
  final Color color;
  final TextStyle baseStyle;

  @override
  ConsumerState<_MessageTextRun> createState() => _MessageTextRunState();
}

class _MessageTextRunState extends ConsumerState<_MessageTextRun> {
  /// Link tap recognizers built for the current spans. A `TextSpan`'s
  /// recognizer is not disposed for you, so they are owned here, rebuilt on
  /// each build and released in [dispose] - a link inside a message row that
  /// scrolls off would otherwise leak one per rebuild.
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

  TapGestureRecognizer _makeLinkRecognizer(String url) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () => openExternalHttpUrl(url);
    _recognizers.add(recognizer);
    return recognizer;
  }

  TapGestureRecognizer _makeMessageLinkRecognizer(String raw) {
    final recognizer = TapGestureRecognizer()..onTap = () => _openMessage(raw);
    _recognizers.add(recognizer);
    return recognizer;
  }

  /// Follows a message link inside the app. Never reaches [launchUrl]: see
  /// [InlineMessageLink] for why that separation is the point.
  ///
  /// A link to another deployment is refused rather than followed, which is the
  /// same call `deep_links.dart` makes about an invite arriving while signed in:
  /// one deployment is one community in v1, so following it would be a server
  /// switch, and that is a product decision a tapped link has no standing to
  /// make.
  void _openMessage(String raw) {
    final link = parseMessageLink(raw);
    if (link == null) return;
    if (!messageLinkIsHere(link, ref.read(serverUrlProvider))) {
      // A server switch is not a tapped link's call; see _openMessage's doc.
      showAppSnackbar(context, 'That link is for a different server.');
      return;
    }
    jumpToMessage(
      GoRouter.of(context),
      ref.read,
      currentChannelId: selectedChannelId(context),
      channelId: link.channelId,
      messageId: link.messageId,
    );
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final style = widget.baseStyle.copyWith(color: widget.color);
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          ..._buildSpans(
            parseInline(widget.text),
            _InlineContext(
              knownUsernames: widget.knownUsernames,
              knownRoleNames: widget.knownRoleNames,
              customEmoji: widget.customEmoji,
              ambientStyle: style,
              linkColor: tokens.accent,
              makeLinkRecognizer: _makeLinkRecognizer,
              makeMessageLinkRecognizer: _makeMessageLinkRecognizer,
            ),
          ),
          if (widget.trailing case final trailing?)
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: Padding(
                padding: const EdgeInsets.only(left: AppSpacing.s4),
                child: trailing,
              ),
            ),
        ],
      ),
    );
  }
}

/// The two reserved mentions `crates/slimm-server/src/push/recipients.rs`
/// resolves specially, never a real account (`validate_username` in
/// `http/auth.rs` refuses to register either, case-insensitively) - kept
/// lower-case, matched the same way against a lower-cased [raw].
const _reservedMentions = {'everyone', 'here'};
