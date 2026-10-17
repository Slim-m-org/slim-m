// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one rule from what this client knows about a person to the presence
/// state drawn for them, on every surface.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'presence_controller.dart';
import '../../../providers/providers.dart';

/// What to draw for one person, given what the server [reported] about them.
///
/// Someone else not yet reported is [AppPresence.unknown], which draws
/// nothing: it must never read as offline. The signed-in user is never
/// unknown to themself, because the client holding this session is itself the
/// connection: an unreported self reads online, and a choice made this session
/// ([chosen]) wins over the report so the footer answers the tap at once.
AppPresence resolvePresence({
  required api.PresenceState? reported,
  required bool isSelf,
  api.PresenceVisibility? chosen,
}) {
  if (isSelf) {
    if (chosen != null) return _chosen(chosen);
    return reported == null ? AppPresence.online : _reported(reported);
  }
  return reported == null ? AppPresence.unknown : _reported(reported);
}

AppPresence _reported(api.PresenceState state) => switch (state) {
  api.PresenceState.online => AppPresence.online,
  api.PresenceState.away => AppPresence.away,
  api.PresenceState.dnd => AppPresence.dnd,
  api.PresenceState.offline => AppPresence.offline,
};

AppPresence _chosen(api.PresenceVisibility visibility) => switch (visibility) {
  api.PresenceVisibility.online => AppPresence.online,
  api.PresenceVisibility.away => AppPresence.away,
  api.PresenceVisibility.dnd => AppPresence.dnd,
  api.PresenceVisibility.hidden => AppPresence.hidden,
};

/// The presence every surface draws for [userId]: the only place the
/// presence map, the session's own id and the caller's own choice meet.
final presenceForProvider = Provider.autoDispose.family<AppPresence, String>((
  ref,
  userId,
) {
  final isSelf = ref.watch(
    sessionProvider.select((session) => session.tokens?.userId == userId),
  );
  final reported = ref.watch(
    presenceControllerProvider.select((map) => map[userId]),
  );
  final chosen = isSelf ? ref.watch(ownVisibilityProvider) : null;
  return resolvePresence(reported: reported, isSelf: isSelf, chosen: chosen);
});

/// What the signed-in user's own surfaces (the footer, the status menu, the
/// tray) draw for them; [AppPresence.unknown] only with no session at all.
final ownPresenceProvider = Provider.autoDispose<AppPresence>((ref) {
  final selfId = ref.watch(sessionProvider).tokens?.userId;
  return selfId == null
      ? AppPresence.unknown
      : ref.watch(presenceForProvider(selfId));
});

/// [presenceForProvider] for many people at once, from one snapshot, for a
/// provider that groups or filters a roster rather than draws it.
Map<String, AppPresence> presenceOfAll(Ref ref, Iterable<String> userIds) {
  final selfId = ref.read(sessionProvider).tokens?.userId;
  final reported = ref.read(presenceControllerProvider);
  final chosen = ref.read(ownVisibilityProvider);
  return {
    for (final id in userIds)
      id: resolvePresence(
        reported: reported[id],
        isSelf: id == selfId,
        chosen: id == selfId ? chosen : null,
      ),
  };
}
