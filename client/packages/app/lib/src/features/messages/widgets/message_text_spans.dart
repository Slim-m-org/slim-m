// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'message_text.dart';

/// Turning parsed inline nodes into the spans a `Text.rich` draws, plus the
/// mention chip one of them renders as.
///
/// Split from `message_text.dart` when the message-link node pushed that file
/// past its hard line ceiling, in the same `part of` shape
/// `message_store_channels.dart` already uses. The seam is widgets versus spans:
/// above is what owns state and lifecycle (the recognizers a tap needs, and
/// their disposal), here is the pure mapping from a node to a span, which has
/// none.

/// Whether [raw] (the whole `@name` token, `@` included) should render as a
/// chip: either it names someone in [knownUsernames], or it is one of the
/// two reserved words above. Rendering a reserved word as a chip says
/// nothing about whether the sender actually held `Perm.mentionEveryone` -
/// that permission only ever gates who gets woken for it, never whether the
/// word itself is recognised - so it is drawn the same way regardless.
bool _isRenderableMention(String raw, Set<String> knownUsernames) {
  final name = raw.substring(1).toLowerCase();
  return knownUsernames.contains(name) || _reservedMentions.contains(name);
}

/// Whether [name] (already brackets-stripped) should render as a role chip:
/// it names a role in [knownRoleNames]. Unlike [_isRenderableMention] there
/// is no reserved-word fallback - `@[everyone]` is a literal role name, not
/// the mass mention, and `roles_for_names` on the server refuses to resolve
/// it for exactly that reason; see its own doc comment.
bool _isRenderableRole(String name, Set<String> knownRoleNames) =>
    knownRoleNames.contains(name.toLowerCase());

/// Walks a [parseInline] tree into `InlineSpan`s. Bold, italic and
/// strikethrough are a style diff on a wrapping [TextSpan]; Flutter merges a
/// child span's style onto its parent's at paint time, which is the whole
/// mechanism nesting rides on: an [InlineBold] wrapping an [InlineItalic]
/// needs no combined style computed here, each node states only its own diff.
/// Everything [_buildSpans] needs beyond the nodes themselves, bundled so the
/// recursion passes one value rather than six and so a link can reach both
/// its colour and the recognizer owner that will dispose it.
class _InlineContext {
  const _InlineContext({
    required this.knownUsernames,
    required this.knownRoleNames,
    required this.customEmoji,
    required this.ambientStyle,
    required this.linkColor,
    required this.makeLinkRecognizer,
    required this.makeMessageLinkRecognizer,
    this.makeEmojiNameSpan,
  });

  final Set<String> knownUsernames;
  final Set<String> knownRoleNames;
  final Map<String, String> customEmoji;
  final TextStyle ambientStyle;
  final Color linkColor;

  /// Creates a tap recognizer for [url] and hands it to whoever owns the
  /// run's lifecycle, so it is disposed with the widget rather than leaked.
  final TapGestureRecognizer Function(String url) makeLinkRecognizer;

  /// The same, for a message link, which is followed inside the app rather than
  /// handed to the OS.
  final TapGestureRecognizer Function(String raw) makeMessageLinkRecognizer;

  /// Wraps a standard emoji in a span that can name it; null leaves emoji as
  /// plain text (a poll's one-line text, which owns no tip).
  final TextSpan Function(String glyph, String name)? makeEmojiNameSpan;
}

List<InlineSpan> _buildSpans(List<InlineNode> nodes, _InlineContext ctx) => [
  for (final node in nodes)
    switch (node) {
      InlineText(:final text) => _textWithEmojiNames(text, ctx),
      InlineCode(:final text) => WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: AppInlineCode(text),
      ),
      InlineMention(:final raw) =>
        _isRenderableMention(raw, ctx.knownUsernames)
            ? WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: _MentionChip(raw),
              )
            : TextSpan(text: raw),
      InlineRoleMention(:final name) =>
        _isRenderableRole(name, ctx.knownRoleNames)
            ? WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: _MentionChip('@$name'),
              )
            : TextSpan(text: '@[$name]'),
      InlineChannelMention(:final channelId) => WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: ChannelMentionChip(channelId: channelId),
      ),
      InlineEmoji(:final raw) => _emojiSpan(raw, ctx.customEmoji),
      InlineLink(:final url) => TextSpan(
        text: url,
        style: TextStyle(
          color: ctx.linkColor,
          decoration: TextDecoration.underline,
          decorationColor: ctx.linkColor,
        ),
        recognizer: ctx.makeLinkRecognizer(url),
        mouseCursor: SystemMouseCursors.click,
      ),
      InlineMessageLink(:final raw) => TextSpan(
        text: 'message link',
        style: TextStyle(
          color: ctx.linkColor,
          decoration: TextDecoration.underline,
          decorationColor: ctx.linkColor,
        ),
        recognizer: ctx.makeMessageLinkRecognizer(raw),
        mouseCursor: SystemMouseCursors.click,
      ),
      InlineBold(:final children) => TextSpan(
        style: const TextStyle(fontWeight: AppWeights.semi),
        children: _buildSpans(children, ctx),
      ),
      InlineItalic(:final children) => TextSpan(
        style: const TextStyle(fontStyle: FontStyle.italic),
        children: _buildSpans(children, ctx),
      ),
      InlineStrikethrough(:final children) => TextSpan(
        style: const TextStyle(decoration: TextDecoration.lineThrough),
        children: _buildSpans(children, ctx),
      ),
      InlineSpoiler(:final children) => WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: MessageSpoiler(
          style: ctx.ambientStyle,
          spans: _buildSpans(children, ctx),
        ),
      ),
    },
];

InlineSpan _emojiSpan(String raw, Map<String, String> customEmoji) {
  final id = customEmojiIdFor(raw, customEmoji);
  return id == null
      ? TextSpan(text: raw)
      : WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Tooltip(
            message: raw,
            waitDuration: emojiNameHoverRest,
            excludeFromSemantics: true,
            child: CustomEmojiImage(emojiId: id, label: raw, size: _emojiSize),
          ),
        );
}

/// The first codepoint a catalog emoji can start with; below it is plain text
/// (Latin, punctuation, the odd trademark sign), which never gets a tip.
const int _emojiFloor = 0x2190;

/// [text] with each standard emoji in its own span from
/// [_InlineContext.makeEmojiNameSpan], the rest left as runs of plain text.
InlineSpan _textWithEmojiNames(String text, _InlineContext ctx) {
  final make = ctx.makeEmojiNameSpan;
  if (make == null || !text.runes.any((r) => r >= _emojiFloor)) {
    return TextSpan(text: text);
  }
  final spans = <InlineSpan>[];
  final plain = StringBuffer();
  for (final glyph in text.characters) {
    final name = glyph.runes.first >= _emojiFloor
        ? standardEmojiShortcode(glyph)
        : null;
    if (name == null) {
      plain.write(glyph);
      continue;
    }
    if (plain.isNotEmpty) {
      spans.add(TextSpan(text: plain.toString()));
      plain.clear();
    }
    spans.add(make(glyph, name));
  }
  if (plain.isNotEmpty) spans.add(TextSpan(text: plain.toString()));
  return spans.length == 1 ? spans.single : TextSpan(children: spans);
}

/// A pill's own padding is layout width: at 4dp a side it read as a second space
/// on each side of the mention, so it stays under half a space.
const double _mentionPillInset = 2;

/// `--accent-text` on `--accent-soft`, matching the design's mention pill.
/// Not a design-system component: a mention is a message-body decoration
/// specific to this screen, not a control other surfaces reuse.
class _MentionChip extends StatelessWidget {
  const _MentionChip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: _mentionPillInset),
      decoration: BoxDecoration(
        color: tokens.accentSoft,
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppText.body.copyWith(
          color: tokens.accent,
          fontWeight: AppWeights.medium,
        ),
      ),
    );
  }
}

/// A `<#id>` channel mention: the channel's name as a tappable chip, or a
/// plain "#unknown-channel" when the local store has no such channel, which is
/// also what a channel this member cannot see looks like.
class ChannelMentionChip extends ConsumerWidget {
  const ChannelMentionChip({super.key, required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final channel = ref.watch(channelByIdProvider(channelId)).valueOrNull;
    final known = channel != null;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: _mentionPillInset),
      decoration: BoxDecoration(
        color: known ? tokens.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Text(
        '#${channel?.name ?? 'unknown-channel'}',
        style: AppText.body.copyWith(
          color: known ? tokens.accent : tokens.textSecondary,
          fontWeight: AppWeights.medium,
        ),
      ),
    );
    if (!known) return chip;
    return Semantics(
      link: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => GoRouter.of(
            context,
          ).go(Routes.channel(channelId, openChat: true)),
          child: SelectionContainer.disabled(child: chip),
        ),
      ),
    );
  }
}

/// Inline-only spans for a single line of text that is not a message body
/// (a poll's question or option): no block markdown, links stay inert.
/// [recognizers] collects what was created so the caller can dispose it.
List<InlineSpan> inlineTextSpans(
  String text, {
  required Map<String, String> customEmoji,
  required TextStyle ambientStyle,
  required Color linkColor,
  required List<TapGestureRecognizer> recognizers,
}) {
  TapGestureRecognizer inert(String _) {
    final recognizer = TapGestureRecognizer();
    recognizers.add(recognizer);
    return recognizer;
  }

  return _buildSpans(
    parseInline(text),
    _InlineContext(
      knownUsernames: const {},
      knownRoleNames: const {},
      customEmoji: customEmoji,
      ambientStyle: ambientStyle,
      linkColor: linkColor,
      makeLinkRecognizer: inert,
      makeMessageLinkRecognizer: inert,
    ),
  );
}
