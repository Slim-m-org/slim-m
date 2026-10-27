// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The command palette's result rows: what counts as a match, and what
/// running one does. Kept apart from the widget so the matching rules are
/// plain top-level functions a test can call without pumping a tree.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import '../../messages/providers/message_search.dart'
    show matchedAttachmentName;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../channels/providers/dms.dart';
import '../../settings/providers/personal_space_visibility.dart';
import '../../members/providers/user_profiles.dart';
import '../../../routing/routes.dart';
import '../../messages/widgets/author_label.dart';
import '../../messages/widgets/message_jump.dart';
import '../../settings/screens/space_settings_section.dart';

/// Which row layout a [PaletteResultItem] draws with.
enum PaletteKind { channel, person, message, action }

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
  final Future<void> Function(BuildContext context, WidgetRef ref) onSelect;
}

/// Whether [channel] is worth showing for [query]. An empty query matches
/// everything, so a blank field browses the whole list rather than showing
/// nothing until the user types.
///
/// A personal space's own name is the fixed sentinel [personalSpaceName],
/// not the caller's own display name, so it also matches on
/// [selfDisplayName] when given. That is what makes this the one way back
/// once the row has been removed from the rail via "Remove from list": the
/// rail row is gone, but typing your own name still finds the channel.
bool channelMatchesQuery(
  Channel channel,
  String query, {
  String? selfDisplayName,
}) {
  if (query.isEmpty) return true;
  final q = query.toLowerCase();
  if (channel.name.toLowerCase().contains(q)) return true;
  return channel.isPersonalSpace &&
      selfDisplayName != null &&
      selfDisplayName.toLowerCase().contains(q);
}

/// Same rule as [channelMatchesQuery], over a member's display name, their
/// username and their role names, since each is something someone might type
/// to find them.
bool memberMatchesQuery(api.UserProfile member, String query) =>
    query.isEmpty ||
    member.displayName.toLowerCase().contains(query.toLowerCase()) ||
    memberMatchReason(member, query) != null;

/// The reason a member matched [query] off their display name, or null when
/// the name itself matched (or the query is empty): the row then says why a
/// person appears under a name that does not contain what was typed.
PaletteReason? memberMatchReason(api.UserProfile member, String query) {
  if (query.isEmpty) return null;
  final q = query.toLowerCase();
  if (member.displayName.toLowerCase().contains(q)) return null;
  if (member.username.toLowerCase().contains(q)) {
    return (label: 'Username', value: member.username);
  }
  for (final role in member.roles) {
    if (role.toLowerCase().contains(q)) return (label: 'Role', value: role);
  }
  return null;
}

const int paletteResultLimit = 8;

/// Channels matching [query], text and voice alike. A DM is a person and is
/// found under Members, so listing it here too showed everyone twice; only the
/// personal space, which has no member row, stays.
///
/// [personalSpaceHidden] keeps a removed personal space out of a blank-query
/// browse of everything - the whole point of removing its row - while
/// [selfDisplayName] (via [channelMatchesQuery]) still surfaces it the
/// moment a real query actually names the caller. Selecting it un-hides it:
/// finding it again is also how it comes back onto the rail.
List<PaletteResultItem> buildChannelItems(
  List<Channel> channels,
  String query, {
  String? selfDisplayName,
  bool personalSpaceHidden = false,
  Map<String, String> categoryNames = const {},
  String? currentChannelId,
}) => [
  for (final channel
      in channels
          .where((c) => c.kind != dmChannelKind || c.isPersonalSpace)
          .where(
            (c) =>
                query.isNotEmpty || !(c.isPersonalSpace && personalSpaceHidden),
          )
          .where(
            (c) =>
                channelMatchesQuery(c, query, selfDisplayName: selfDisplayName),
          )
          .take(paletteResultLimit))
    PaletteResultItem(
      label: channel.name,
      kind: PaletteKind.channel,
      channel: channel,
      categoryName: categoryNames[channel.categoryId],
      isCurrent: channel.id == currentChannelId,
      onSelect: (context, ref) async {
        if (channel.isPersonalSpace) {
          await ref.read(personalSpaceVisibilityProvider.notifier).show();
        }
        if (context.mounted) context.go(Routes.channel(channel.id));
      },
    ),
];

/// Members matching [query], excluding [selfId]. A DM with yourself is a
/// personal space now and opens fine, but it has its own dedicated row in
/// the rail's Direct messages section - finding it by searching your own
/// name here would be the opposite of obvious.
List<PaletteResultItem> buildMemberItems(
  List<api.UserProfile> members,
  String query,
  String? selfId,
) => [
  for (final member
      in members
          .where((m) => m.id != selfId)
          .where((m) => memberMatchesQuery(m, query))
          .take(paletteResultLimit))
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
}) => [
  for (final message in messages)
    PaletteResultItem(
      label: message.content.isEmpty
          ? (matchedAttachmentName(message) ?? '')
          : message.content,
      kind: PaletteKind.message,
      message: message,
      messageChannelLabel: _messageChannelLabel(
        channelsById[message.channelId],
      ),
      onSelect: (context, ref) async => jumpToMessage(
        GoRouter.of(context),
        ref.read,
        currentChannelId: currentChannelId,
        channelId: message.channelId,
        messageId: message.id,
      ),
    ),
];

String _messageChannelLabel(Channel? channel) => switch (channel) {
  null => 'a channel',
  Channel(kind: dmChannelKind) => 'a direct message',
  Channel(:final name) => '#$name',
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
  ];
  if (query.isEmpty) return actions;
  final q = query.toLowerCase();
  return actions.where((a) => a.label.toLowerCase().contains(q)).toList();
}
