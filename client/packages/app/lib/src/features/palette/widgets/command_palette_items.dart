// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The command palette's result rows: what counts as a match, and what
/// running one does. Kept apart from the widget so the matching rules are
/// plain top-level functions a test can call without pumping a tree.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import '../../messages/providers/message_search.dart'
    show matchedAttachmentName, matchedVoiceTranscript;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../channels/providers/dms.dart';
import '../../channels/widgets/new_group_dm_sheet.dart';
import '../../members/providers/user_profiles.dart';
import '../../../routing/routes.dart';
import '../../messages/widgets/author_label.dart';
import '../../messages/widgets/message_jump.dart';
import '../../settings/screens/space_settings_section.dart';
import '../../messages/widgets/message_inline.dart' show rewriteMentions;

/// Which row layout a [PaletteResultItem] draws with.
enum PaletteKind { channel, person, message, transcript, action, filter }

/// Which sections a query asks for: a leading `#` narrows to channels and a
/// leading `@` to people, so a type-ahead habit from other chat apps works.
enum PaletteScope { all, channels, people }

/// [raw] split into its section scope and the text to match.
({PaletteScope scope, String text}) parsePaletteQuery(String raw) {
  if (raw.startsWith('#')) {
    return (scope: PaletteScope.channels, text: raw.substring(1).trimLeft());
  }
  if (raw.startsWith('@')) {
    return (scope: PaletteScope.people, text: raw.substring(1).trimLeft());
  }
  return (scope: PaletteScope.all, text: raw);
}

/// Why a person matched when it was not on their display name.
typedef PaletteReason = ({String label, String value});

/// A running palette result: what to render, and what selecting it does.
/// [onSelect] receives the still-mounted palette's own context and ref, so it
/// can navigate or await a request before the caller pops it.
class PaletteResultItem {
  const PaletteResultItem({
    required this.label,
    required this.onSelect,
    this.kind = PaletteKind.action,
    this.leading,
    this.semanticLabel,
    this.channel,
    this.categoryName,
    this.isCurrent = false,
    this.member,
    this.reason,
    this.message,
    this.messageChannelLabel,
    this.transcript,
    this.showsAllOf,
    this.hint,
    this.keepsOpen = false,
  });

  final String label;
  final PaletteKind kind;

  /// An action's glyph; channel and person rows draw their own.
  final IconData? leading;
  final String? semanticLabel;
  final Channel? channel;
  final String? categoryName;
  final bool isCurrent;
  final api.UserProfile? member;
  final PaletteReason? reason;
  final api.Message? message;
  final String? messageChannelLabel;
  final api.TranscriptHit? transcript;

  /// Set on the row that lists a capped section whole: how many matched. It keeps the palette open.
  final int? showsAllOf;

  /// A filter suggestion's quieter second label, such as a username.
  final String? hint;

  /// Running it changes the search rather than leaving it, so the palette stays.
  final bool keepsOpen;
  final Future<void> Function(BuildContext context, WidgetRef ref) onSelect;
}

/// [items] cut to [paletteResultLimit], ending in a row that calls [showAll] when more matched.
List<PaletteResultItem> capWithShowAll(
  List<PaletteResultItem> items, {
  required String noun,
  required VoidCallback showAll,
}) {
  if (items.length <= paletteResultLimit) return items;
  return [
    ...items.take(paletteResultLimit),
    PaletteResultItem(
      label: 'Show all ${items.length} $noun',
      leading: AppIcons.chevronDown,
      showsAllOf: items.length,
      onSelect: (_, _) async => showAll(),
    ),
  ];
}

/// Whether [channel] is worth showing for [query]. An empty query matches
/// everything, so a blank field browses the whole list rather than showing
/// nothing until the user types. Both sides drop combining marks, so a
/// decorated name is found by its plain letters.
///
/// A personal space's own name is the fixed sentinel [personalSpaceName],
/// not the caller's own display name, so it also matches on
/// [selfDisplayName] when given: someone looking for their own notes may
/// type their own name.
bool channelMatchesQuery(
  Channel channel,
  String query, {
  String? selfDisplayName,
}) {
  if (query.isEmpty) return true;
  final q = api.foldMarks(query);
  if (api.foldMarks(channel.name).contains(q)) return true;
  return channel.isPersonalSpace &&
      selfDisplayName != null &&
      api.foldMarks(selfDisplayName).contains(q);
}

/// Same rule as [channelMatchesQuery], over a member's display name, their
/// username and their role names, since each is something someone might type
/// to find them.
bool memberMatchesQuery(api.UserProfile member, String query) =>
    query.isEmpty ||
    api.foldMarks(member.displayName).contains(api.foldMarks(query)) ||
    memberMatchReason(member, query) != null;

/// The reason a member matched [query] off their display name, or null when
/// the name itself matched (or the query is empty): the row then says why a
/// person appears under a name that does not contain what was typed.
PaletteReason? memberMatchReason(api.UserProfile member, String query) {
  if (query.isEmpty) return null;
  final q = api.foldMarks(query);
  if (api.foldMarks(member.displayName).contains(q)) return null;
  if (member.username.toLowerCase().contains(q)) {
    return (label: 'Username', value: member.username);
  }
  for (final role in member.roles) {
    if (api.foldMarks(role).contains(q)) return (label: 'Role', value: role);
  }
  return null;
}

const int paletteResultLimit = 8;

/// Channels matching [query], text and voice alike. A one-to-one DM is a
/// person and is found under Members, so listing it here too showed everyone
/// twice; only the personal space, Notes, which has no member row, stays -
/// found by its name or by the caller's own display name (via
/// [channelMatchesQuery]). Group DMs have no single member row and are found
/// by [buildGroupDmItems].
List<PaletteResultItem> buildChannelItems(
  List<Channel> channels,
  String query, {
  String? selfDisplayName,
  Map<String, String> categoryNames = const {},
  String? currentChannelId,
  int? limit = paletteResultLimit,
}) => [
  for (final channel
      in channels
          .where((c) => c.kind != dmChannelKind || c.isPersonalSpace)
          .where(
            (c) =>
                channelMatchesQuery(c, query, selfDisplayName: selfDisplayName),
          )
          .take(limit ?? channels.length))
    PaletteResultItem(
      label: channel.name,
      kind: PaletteKind.channel,
      channel: channel,
      categoryName: categoryNames[channel.categoryId],
      isCurrent: channel.id == currentChannelId,
      onSelect: (context, ref) async => context.go(Routes.channel(channel.id)),
    ),
];

/// The Channels and Group chats sections; with [showAll] each is capped and ends in a row that lists it whole.
List<(String, List<PaletteResultItem>)> channelSections(
  List<Channel> channels,
  String query, {
  String? selfDisplayName,
  Map<String, String> categoryNames = const {},
  String? currentChannelId,
  VoidCallback? showAll,
}) {
  List<PaletteResultItem> capped(List<PaletteResultItem> all, String noun) =>
      showAll == null ? all : capWithShowAll(all, noun: noun, showAll: showAll);
  return [
    (
      'Channels',
      capped(
        buildChannelItems(
          channels,
          query,
          selfDisplayName: selfDisplayName,
          categoryNames: categoryNames,
          currentChannelId: currentChannelId,
          limit: null,
        ),
        'channels',
      ),
    ),
    (
      'Group chats',
      capped(
        buildGroupDmItems(
          channels,
          query,
          currentChannelId: currentChannelId,
          limit: null,
        ),
        'group chats',
      ),
    ),
  ];
}

/// Group DMs matching [query], by the name the rail lists them under.
List<PaletteResultItem> buildGroupDmItems(
  List<Channel> channels,
  String query, {
  String? currentChannelId,
  int? limit = paletteResultLimit,
}) => [
  for (final channel
      in channels
          .where((c) => c.isGroupDm)
          .where((c) => channelMatchesQuery(c, query))
          .take(limit ?? channels.length))
    PaletteResultItem(
      label: channel.name,
      kind: PaletteKind.channel,
      channel: channel,
      isCurrent: channel.id == currentChannelId,
      onSelect: (context, ref) async => context.go(Routes.channel(channel.id)),
    ),
];

/// [members] with everyone in [around] ahead of everyone who is not, each
/// side keeping its own order.
List<api.UserProfile> onlineFirst(
  List<api.UserProfile> members,
  Set<String> around,
) => [
  ...members.where((m) => around.contains(m.id)),
  ...members.where((m) => !around.contains(m.id)),
];

/// Members matching [query], excluding [selfId], with no cap: the list
/// scrolls, and a person past the eighth was otherwise unreachable by
/// browsing. [around] puts the people who are around first. A DM with
/// yourself is a personal space now and opens fine, but it is Notes, listed
/// under Channels and reached from the rail's Notes button - finding it under
/// People by your own name would be the opposite of obvious.
List<PaletteResultItem> buildMemberItems(
  List<api.UserProfile> members,
  String query,
  String? selfId, {
  Set<String> around = const {},
}) => [
  for (final member in onlineFirst(
    members,
    around,
  ).where((m) => m.id != selfId).where((m) => memberMatchesQuery(m, query)))
    PaletteResultItem(
      label: member.displayName,
      kind: PaletteKind.person,
      member: member,
      reason: memberMatchReason(member, query),
      semanticLabel: 'Message ${member.displayName}',
      onSelect: (context, ref) async {
        final container = ProviderScope.containerOf(context, listen: false);
        final channelId = await openDirectMessage(container, member.id);
        if (context.mounted) context.go(Routes.channel(channelId));
      },
    ),
];

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

/// The palette's static actions, filtered by [query] like everything else.
/// The Space settings action is gated on [permissions] the same way the
/// rail's Space menu is, so the palette never offers a path this caller
/// could not also reach from the rail.
List<PaletteResultItem> buildActionItems(String query, int permissions) {
  final actions = [
    // push, not go: settings float as a modal over the app, so they need the
    // shell left beneath them, exactly as every rail entry point does. go
    // replaced the shell, so closing the modal stranded the user on the empty
    // channel view with the open channel lost. The channel entries above stay
    // on go, since a channel is a shell route and replacing is right there.
    PaletteResultItem(
      label: 'Open personal settings',
      kind: PaletteKind.action,
      leading: AppIcons.settings,
      onSelect: (context, ref) async => context.push(Routes.personalSettings),
    ),
    if (spaceSettingsReachable(permissions))
      PaletteResultItem(
        label: 'Open Space settings',
        kind: PaletteKind.action,
        leading: AppIcons.settings,
        onSelect: (context, ref) async => context.push(Routes.spaceSettings),
      ),
    PaletteResultItem(
      label: 'New group message',
      kind: PaletteKind.action,
      leading: AppIcons.members,
      // After the palette has closed, from a context that outlives it: never a sheet stacked on the palette.
      onSelect: (context, ref) async {
        final shell = GoRouter.of(context).routerDelegate.navigatorKey;
        unawaited(
          Future<void>.microtask(() {
            final host = shell.currentContext;
            if (host != null && host.mounted) {
              unawaited(showNewGroupDmSheet(host));
            }
          }),
        );
      },
    ),
  ];
  if (query.isEmpty) return actions;
  final q = query.toLowerCase();
  return actions.where((a) => a.label.toLowerCase().contains(q)).toList();
}
