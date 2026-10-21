// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The offers for an open trigger, watched from the providers behind them.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:slimm_api/api.dart' show App, ChannelBotCommand, SlashCommand;

import '../../../permissions.dart';
import '../../../providers/admin_providers.dart';
import '../../../providers/providers.dart';
import '../../channels/providers/channel_permissions.dart';
import '../../members/providers/member_presence.dart' show membersProvider;
import 'composer_autocomplete_items.dart';
import 'composer_autocomplete_query.dart';

/// Rebuilt during build rather than stored, since the member list and the
/// Space's emoji are both watched providers and either can arrive late.
List<AutocompleteSuggestion> watchAutocompleteSuggestions(
  WidgetRef ref, {
  required AutocompleteQuery? query,
  required String channelId,
  required List<SlashCommand> slashCommands,
  required List<App> apps,
  required List<ChannelBotCommand> botCommands,
  required bool gifSearch,
}) {
  if (query == null) return const [];
  return autocompleteSuggestions(
    query: query,
    custom: ref.watch(customEmojiProvider).valueOrNull ?? const [],
    members: ref.watch(membersProvider).valueOrNull ?? const [],
    selfId: ref.watch(meProvider).valueOrNull?.id,
    canMentionEveryone: ref
        .watch(myChannelPermissionsProvider(channelId))
        .hasPermission(Perm.mentionEveryone),
    slashCommands: slashCommands,
    apps: apps,
    botCommands: botCommands,
    gifSearch: gifSearch,
  );
}
