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
}

List<InlineSpan> _buildSpans(List<InlineNode> nodes, _InlineContext ctx) => [
  for (final node in nodes)
    switch (node) {
      InlineText(:final text) => TextSpan(text: text),
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
          child: CustomEmojiImage(emojiId: id, label: raw, size: _emojiSize),
        );
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
        style: AppText.body.copyWith(
          color: tokens.accent,
          fontWeight: AppWeights.medium,
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
