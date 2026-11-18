// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who a role's Members tab offers to add, most recently active first.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../format.dart';
import '../../../providers/providers.dart';
import '../../../role_ladder.dart';

/// When each member last posted where the viewer can read, by user id.
final memberActivityProvider = FutureProvider.autoDispose<Map<String, int>>(
  (ref) => ref.watch(apiProvider).listMemberActivity(),
);

/// The members [role] could be given, newest poster first, then by name.
///
/// With an empty [query] bots are left out, since a bot's roles usually come
/// with the bot; a search finds them like anyone else.
List<api.UserProfile> roleCandidates({
  required List<api.UserProfile> members,
  required api.Role role,
  required RoleLadder ladder,
  required Map<String, int> activity,
  String query = '',
}) {
  final needle = query.trim().toLowerCase();
  bool matches(api.UserProfile m) => needle.isEmpty
      ? !m.isBot
      : m.displayName.toLowerCase().contains(needle) ||
            m.username.toLowerCase().contains(needle);
  return [
    for (final m in members)
      if (!m.roleIds.contains(role.id) &&
          matches(m) &&
          ladder.lockOf(role, member: m, held: false) == null)
        m,
  ]..sort((a, b) {
    final byActivity = (activity[b.id] ?? -1).compareTo(activity[a.id] ?? -1);
    if (byActivity != 0) return byActivity;
    return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  });
}

/// "Posted 3d ago", or "No posts yet" for a member with no [lastPostedAt].
String postedLabel(int? lastPostedAt, {DateTime? now}) =>
    switch (lastPostedAt) {
      final at? => 'Posted ${formatRelativeAgeMs(at, now: now, weeks: true)}',
      null => 'No posts yet',
    };
