// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The node types `parseInline` produces.
library;

/// One node of a parsed inline run. Leaves carry raw, unresolved text for the
/// two tokens whose meaning depends on data this file does not have
/// ([InlineMention] against a member list, [InlineEmoji] against a custom
/// emoji index); resolving them is `message_text.dart`'s job.
sealed class InlineNode {
  const InlineNode();
}

class InlineText extends InlineNode {
  const InlineText(this.text);
  final String text;
}

/// Raw content between a matched pair of backticks. Never itself parsed for
/// markdown, since code is quoted exactly as typed.
class InlineCode extends InlineNode {
  const InlineCode(this.text);
  final String text;
}

/// The raw `@name` token, including the `@`.
class InlineMention extends InlineNode {
  const InlineMention(this.raw);
  final String raw;
}

/// A role mention's name, brackets stripped and trimmed: `@[Core Team]`
/// parses to `Core Team`. Its own bracketed grammar rather than a widened
/// [InlineMention] charset, so a role name can hold spaces and mixed case,
/// and so a role and a user sharing a name are never ambiguous - `@nick` is
/// always [InlineMention], `@[nick]` is always this. Matched the identical
/// way in `mentioned_role_names` (`crates/slimm-server/src/push/
/// recipients.rs`).
class InlineRoleMention extends InlineNode {
  const InlineRoleMention(this.name);
  final String name;
}

/// The raw `:shortcode:` token, including both colons.
class InlineEmoji extends InlineNode {
  const InlineEmoji(this.raw);
  final String raw;
}

/// A bare http/https URL typed into a message, to render as a tappable link.
/// [url] is exactly the matched text with trailing sentence punctuation
/// trimmed off (see [_trimUrlEnd]); the scheme is guaranteed http or https by
/// [_urlPattern], so nothing here can smuggle a `file:` or app scheme past
/// the opener.
class InlineLink extends InlineNode {
  const InlineLink(this.url, {this.noPreview = false});
  final String url;

  /// Written as `<https://...>`, which asks for the link without a preview card.
  final bool noPreview;
}

/// A `slimm://message?...` link typed or pasted into a message.
///
/// Deliberately its own node rather than an [InlineLink] with a different
/// scheme. [InlineLink] is what `message_text.dart` hands to `launchUrl`, and
/// that path checks for http or https precisely so nothing can smuggle an app
/// scheme past the opener. A message link is never opened by the OS at all: it
/// is navigation inside this app, so it takes a separate route through the
/// renderer and that guard stays exactly as tight as it was.
class InlineMessageLink extends InlineNode {
  const InlineMessageLink(this.raw);

  /// The matched text, still to be parsed by `parseMessageLink`. Kept raw so
  /// this file needs no opinion about what a valid one looks like.
  final String raw;
}

/// A `<#channel-id>` token: a link to a channel, resolved to its name at draw
/// time because only the renderer has the channel list.
class InlineChannelMention extends InlineNode {
  const InlineChannelMention(this.channelId);
  final String channelId;
}

class InlineBold extends InlineNode {
  const InlineBold(this.children);
  final List<InlineNode> children;
}

class InlineItalic extends InlineNode {
  const InlineItalic(this.children);
  final List<InlineNode> children;
}

class InlineStrikethrough extends InlineNode {
  const InlineStrikethrough(this.children);
  final List<InlineNode> children;
}

class InlineSpoiler extends InlineNode {
  const InlineSpoiler(this.children);
  final List<InlineNode> children;
}
