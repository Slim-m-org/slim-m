// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How the member pane sections its roster: one section per hoisted role,
/// then Online, Offline and Bots.
///
/// A member is listed under the highest-position hoisted role they hold, as
/// the server reports it on the profile, and only while online. `GET /roles`
/// needs MANAGE_ROLES, so sections order by the position carried on each
/// member, which keeps the pane identical for every viewer.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'member_presence.dart';
import 'presence_controller.dart';
import 'presence_view.dart';

/// Online members whose top hoisted role is [roleId], listed under [name].
typedef RoleSection = ({
  String roleId,
  String name,
  List<api.UserProfile> members,
});

/// The roster split into the sections the pane shows, top to bottom.
class RosterGroups {
  const RosterGroups({
    this.roles = const [],
    this.online = const [],
    this.offline = const [],
    this.bots = const [],
  });

  final List<RoleSection> roles;
  final List<api.UserProfile> online;
  final List<api.UserProfile> offline;
  final List<api.UserProfile> bots;
}

/// The hoisted role a member is listed under, or null when none of theirs is
/// hoisted.
///
/// Null too on a server that sends no hoisted role, or an id that is not among
/// the member's own roles, since a section keyed on a guess would be worse than
/// none.
({String id, String name, int position})? hoistedRoleOf(
  api.UserProfile member,
) {
  final id = member.hoistedRoleId;
  final position = member.hoistedRolePosition;
  if (id == null || position == null) return null;
  final index = member.roleIds.indexOf(id);
  if (index < 0 || index >= member.roles.length) return null;
  return (id: id, name: member.roles[index], position: position);
}

/// Splits [members] into role sections, online, offline and bots, each
/// name-sorted. A member absent from [statusOf] counts as offline, the only
/// honest default when presence is unknown.
RosterGroups groupRoster(
  List<api.UserProfile> members,
  Map<String, AppPresence> statusOf,
) {
  final byRole = <String, List<api.UserProfile>>{};
  final sectionOf = <String, ({String name, int position})>{};
  final online = <api.UserProfile>[];
  final offline = <api.UserProfile>[];
  final bots = <api.UserProfile>[];
  for (final member in members) {
    if (member.isBot) {
      bots.add(member);
      continue;
    }
    final status = statusOf[member.id];
    if (status == null || !isReachablePresence(status)) {
      offline.add(member);
      continue;
    }
    final hoisted = hoistedRoleOf(member);
    if (hoisted == null) {
      online.add(member);
      continue;
    }
    sectionOf[hoisted.id] = (name: hoisted.name, position: hoisted.position);
    (byRole[hoisted.id] ??= []).add(member);
  }
  int byName(api.UserProfile a, api.UserProfile b) =>
      a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  online.sort(byName);
  offline.sort(byName);
  bots.sort(byName);
  final order = byRole.keys.toList()
    ..sort((a, b) {
      final byPosition = sectionOf[b]!.position.compareTo(
        sectionOf[a]!.position,
      );
      if (byPosition != 0) return byPosition;
      final byRoleName = sectionOf[a]!.name.toLowerCase().compareTo(
        sectionOf[b]!.name.toLowerCase(),
      );
      return byRoleName != 0 ? byRoleName : a.compareTo(b);
    });
  final sections = [
    for (final id in order)
      (
        roleId: id,
        name: sectionOf[id]!.name,
        members: byRole[id]!..sort(byName),
      ),
  ];
  return RosterGroups(
    roles: sections,
    online: online,
    offline: offline,
    bots: bots,
  );
}

/// One row of the member pane's roster: a group heading or a member.
sealed class RosterEntry {
  const RosterEntry();
}

final class RosterGroupLabel extends RosterEntry {
  const RosterGroupLabel(this.text);
  final String text;
}

final class RosterMember extends RosterEntry {
  const RosterMember(this.profile, {this.sectionRoleId});
  final api.UserProfile profile;

  /// The role whose section this row sits under, so its badge can be left off.
  final String? sectionRoleId;
}

/// [groups] flattened into the rows the pane lays out, each non-empty group
/// as its heading followed by its members, so a lazy list builds only the
/// rows on screen. Bots come last whatever their presence.
List<RosterEntry> rosterEntries(RosterGroups groups) => [
  for (final section in groups.roles) ...[
    RosterGroupLabel('${section.name} · ${section.members.length}'),
    for (final m in section.members)
      RosterMember(m, sectionRoleId: section.roleId),
  ],
  if (groups.online.isNotEmpty) ...[
    RosterGroupLabel('Online · ${groups.online.length}'),
    for (final m in groups.online) RosterMember(m),
  ],
  if (groups.offline.isNotEmpty) ...[
    RosterGroupLabel('Offline · ${groups.offline.length}'),
    for (final m in groups.offline) RosterMember(m),
  ],
  if (groups.bots.isNotEmpty) ...[
    RosterGroupLabel('Bots · ${groups.bots.length}'),
    for (final m in groups.bots) RosterMember(m),
  ],
];

/// The pane's rows for [channelId]'s roster, rebuilt only when the roster or
/// who is reachable changes, so a selection toggle or a dot changing colour
/// does not regroup a large roster.
final rosterEntriesProvider = Provider.autoDispose
    .family<List<RosterEntry>, String?>((ref, channelId) {
      final members = channelId == null
          ? ref.watch(membersProvider)
          : ref.watch(channelMembersProvider(channelId));
      ref.watch(presenceControllerProvider.select(reachablePresenceKey));
      ref.watch(ownVisibilityProvider);
      final roster = members.valueOrNull ?? [];
      final statusOf = presenceOfAll(ref, roster.map((m) => m.id));
      return rosterEntries(groupRoster(roster, statusOf));
    });
