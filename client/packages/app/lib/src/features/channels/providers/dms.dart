// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Direct-message conversations.
///
/// A DM is an ordinary channel once opened (`GET /channels/{id}/messages`,
/// search, and `/sync` all work on it unchanged), so this file does not give
/// DMs a parallel data model. It exists only to get one into the local store
/// under the same [api.Channel] shape every other channel arrives as.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';
import 'group_dm.dart' show channelFromGroupDm;

/// The wire kind a DM channel's local row is stored under. Matches the
/// server's own `kind = 'dm'` column value (see `store/dms.rs`), so a
/// restored local row and a freshly synced one agree.
const String dmChannelKind = 'dm';

/// Display copy for a personal space's channel row: a DM opened with
/// yourself (`store/dms.rs` no longer refuses `caller == target`), used for
/// private notes that still sync across every signed-in device the way any
/// other channel does.
///
/// `Notes`, not `You`: reversed at the owner's direction after this string
/// shipped as `You` for a while. The earlier reasoning leaned on two
/// pillars - it matched the second-person convention used for the caller
/// elsewhere (a voice tile's `$name (you)`, the personal settings screen's
/// own `You` section group), and it composed with the composer placeholder
/// so `Message #$personalSpaceName` read as an instruction rather than the
/// app talking about itself. Both still describe `You`'s trade-offs
/// accurately; they were outweighed, not wrong. `Notes` names what the row
/// is *for* rather than who it belongs to, which is the more useful fact
/// once a caller has more than a couple of DMs: `You` looks like a person in
/// a list of people, `Notes` reads immediately as the one row that is not a
/// conversation. It also matches the notebook glyph [PersonalSpaceRow]
/// already gives this row - a label finally naming what the icon has been
/// saying - and `Message #Notes` composes at least as well as `Message You`
/// did, describing an action ("jot something down") instead of asking the
/// reader to parse a pronoun. `You`'s alignment with the settings group's
/// own label does not carry over, but that pairing was never load-bearing:
/// the settings group names *your account settings*, this row names *a
/// notes channel*, and losing an accidental echo between two different
/// things does not resurrect the case for the pronoun.
///
/// Purely cosmetic - another member can set this exact string as their own
/// display name, and a DM with them would render the same label.
/// [Channel.isPersonalSpace] (`api.Channel`), not this string, is what the
/// rail matches on; see [channelFromDm]. A caller hunting for this channel by
/// their own real display name rather than this sentinel still finds it:
/// `command_palette_items.dart`'s `channelMatchesQuery` matches a personal
/// space against the caller's own display name too, which is also the one
/// way back once its rail row has been removed via "Remove from list".
const String personalSpaceName = 'Notes';

/// Turns a DM listing into the same [api.Channel] shape an ordinary channel
/// arrives as. The server stores a DM channel's own `name` as empty (a DM
/// has no name of its own), so the other participant's display name stands
/// in for it here - except when that participant is the caller: a personal
/// space labelled with your own name would read as a DM with yourself
/// rather than what it is. Every screen that shows a channel's name already
/// reads it off the local store rather than the server's channel list, so
/// this is the only place that substitution needs to happen.
///
/// [dm.user.id == selfId] is also what sets [api.Channel.isPersonalSpace]:
/// this is the one place that comparison is made, so it is the one place
/// that can answer "is this my personal space" reliably. The [name] set
/// above must never be asked that question instead - a member is free to
/// set their own display name to [personalSpaceName], and nothing stops a
/// DM with them from carrying that exact string too. [dm.user.id] is also
/// persisted as [api.Channel.dmParticipantId], so a caller that needs it
/// (blocking) reads it off the local row rather than fetching `/dms` again.
api.Channel channelFromDm(api.DmConversation dm, {required String? selfId}) {
  if (dm.isGroup) return channelFromGroupDm(dm, selfId: selfId);
  final isSelf = dm.user.id == selfId;
  return api.Channel(
    id: dm.channelId,
    name: isSelf ? personalSpaceName : dm.user.displayName,
    kind: dmChannelKind,
    createdAt: dm.createdAt,
    isPersonalSpace: isSelf,
    dmParticipantId: dm.user.id,
  );
}

/// Opens (or returns) the DM with [userId] - or, passing your own id, your
/// personal space - and gets it into the local store, so the screen this
/// navigates to has a name and kind to render immediately rather than
/// waiting on the next reconnect's channel refresh.
///
/// Takes a [ProviderContainer] rather than a [WidgetRef]: a caller that
/// dismisses its own surface before this answers (the member popover's
/// "Message" row) needs a handle that outlives that surface, and a container
/// is exactly that.
Future<String> openDirectMessage(
  ProviderContainer container,
  String userId,
) async {
  final client = container.read(apiProvider);
  final conversation = await client.openDirectMessage(userId);
  final store = await container.read(storeProvider.future);
  await store.upsertChannels([
    channelFromDm(conversation, selfId: client.session.tokens?.userId),
  ]);
  return conversation.channelId;
}

/// Closes the DM with [userId] out of this device's own sidebar - a
/// per-viewer hide on the server (see `POST /dms/{userId}`'s sibling
/// `DELETE`), never a delete: no message is touched, the other
/// participant's own list is unaffected, and it comes back on its own once
/// they send something new or the caller opens or messages them again.
///
/// [channelId] is dropped from the local store via `removeChannel`, the same
/// call already used for any channel the server has stopped listing, so the
/// row leaves the rail immediately rather than waiting on the next periodic
/// refresh - its cached messages go with it, which costs nothing: reopening
/// refetches history from the server the way any freshly (re)synced channel
/// already does.
Future<void> hideDmConversation(
  ProviderContainer container,
  String userId,
  String channelId,
) async {
  final client = container.read(apiProvider);
  await client.hideDirectMessage(userId);
  final store = await container.read(storeProvider.future);
  await store.removeChannel(channelId);
}
