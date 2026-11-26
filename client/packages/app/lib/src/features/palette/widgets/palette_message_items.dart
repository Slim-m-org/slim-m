// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The palette's message-hit rows: how a hit is labelled, spoken and opened.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../channels/providers/dms.dart' show dmChannelKind;
import '../../members/providers/user_profiles.dart';
import '../../messages/providers/message_search.dart'
    show matchedAttachmentName, matchedVoiceTranscript;
import '../../messages/widgets/author_label.dart';
import '../../messages/widgets/message_inline.dart' show rewriteMentions;
import '../../messages/widgets/message_jump.dart';
import 'command_palette_items.dart';

/// Messages already matched server-side by full-text search across every
/// channel the caller can view (`GET /search/messages`), not only whichever
/// one is open.
///
/// [currentChannelId] is the palette's own `widget.currentChannelId`, taken
/// from the caller rather than read here with `selectedChannelId(context)`:
/// that needs a `GoRouterState`, which only resolves inside a route's own
/// builder subtree, and the palette's context is a dialog sitting outside
/// all of them.
List<PaletteResultItem> buildMessageItems(
  List<api.Message> messages, {
  required String? currentChannelId,
  Map<String, Channel> channelsById = const {},
  Map<String, String> mentionNames = const {},
}) => [
  for (final message in messages)
    messageResultItem(
      message,
      channelLabel: paletteHitChannelLabel(message, channelsById),
      authorName: message.authorDisplayName,
      mentionNames: mentionNames,
      onSelect: (context, ref) async => jumpToMessage(
        GoRouter.of(context),
        ref.read,
        currentChannelId: currentChannelId,
        channelId: message.channelId,
        messageId: message.id,
        inThread: message.threadParentChannelId != null,
      ),
    ),
];

/// One message hit as a palette row: its text, or the file's name when only
/// the file matched, and where it was said. A caller that has resolved
/// [authorName] gets a screen-reader label that says who wrote it.
PaletteResultItem messageResultItem(
  api.Message message, {
  required String channelLabel,
  String? authorName,
  Map<String, String> mentionNames = const {},
  required Future<void> Function(BuildContext context, WidgetRef ref) onSelect,
}) {
  final label = message.content.isEmpty
      ? (matchedVoiceTranscript(message) ??
            matchedAttachmentName(message) ??
            '')
      : message.content;
  final spoken = searchHitSpokenLabel(
    message,
    authorName: authorName,
    mentionNames: mentionNames,
  );
  return PaletteResultItem(
    label: label,
    semanticLabel: spoken == label ? null : spoken,
    kind: PaletteKind.message,
    message: message,
    messageChannelLabel: channelLabel,
    onSelect: onSelect,
  );
}

/// How a message hit is read aloud, the same in the palette and at every
/// search width: what matched, and the file it was found in.
String searchHitSpokenLabel(
  api.Message message, {
  String? authorName,
  Map<String, String> mentionNames = const {},
}) {
  final said = matchedVoiceTranscript(message);
  final file = said == null
      ? matchedAttachmentName(message)
      : 'a voice message';
  final what = [
    // Read aloud the way the chips show it: the member's name, not the stored @username.
    if (message.content.isNotEmpty)
      rewriteMentions(message.content, mentionNames),
    ?said,
    if (file != null) 'found in $file',
  ].join(', ');
  return authorName == null ? what : 'Message from $authorName: $what';
}

/// How a message hit names the conversation it was said in.
String paletteChannelLabel(Channel? channel) => switch (channel) {
  null => 'a channel',
  Channel(kind: dmChannelKind) => 'a direct message',
  Channel(:final name) when name.isEmpty => 'a thread',
  Channel(:final name) => '#$name',
};

/// Where a message hit was said; a thread reply names the channel its thread hangs off.
String paletteHitChannelLabel(
  api.Message message,
  Map<String, Channel> channelsById,
) => switch (message.threadParentChannelId) {
  null => paletteChannelLabel(channelsById[message.channelId]),
  final parent => 'a thread in ${paletteChannelLabel(channelsById[parent])}',
};

/// A message hit's trailing author label: selects only its own author's
/// slice of [batchProfilesControllerProvider], so an unrelated author
/// resolving does not rebuild every row in the palette's result list - see
/// `message_row_identity.dart`.
class PaletteMessageAuthor extends ConsumerWidget {
  const PaletteMessageAuthor({
    super.key,
    required this.authorId,
    required this.cachedDisplayName,
    this.style,
  });

  final String? authorId;
  final String? cachedDisplayName;

  /// Defaults to the micro secondary style a trailing label used to have.
  final TextStyle? style;

  /// Bounds the name so a long or claimed one cannot grow into the row's
  /// message-content column instead of ellipsizing in its own trailing
  /// slot - `AppMenuItem`'s own `trailing` sits in a `Row` with
  /// `MainAxisSize.min`, so nothing here shrinks it for free.
  static const double _maxWidth = 140;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final resolution = ref.watch(
      batchProfilesControllerProvider.select(
        (m) => authorResolution(m, authorId ?? ''),
      ),
    );
    final name = authorLabelResolved(
      authorId: authorId,
      cachedDisplayName: cachedDisplayName,
      resolution: resolution,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxWidth),
      child: AuthorNameLine(
        name: name,
        profile: resolution.profile,
        style: style ?? AppText.micro.copyWith(color: tokens.textSecondary),
      ),
    );
  }
}
