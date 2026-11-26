// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a message's own text pings the viewer by name, rather than only by replying to them.
library;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart' show sessionProvider;
import '../../members/providers/member_presence.dart';

/// The names that ping the viewer: their username and the roles they hold.
class ViewerMentionTargets {
  const ViewerMentionTargets({this.username, this.roles = const []});

  final String? username;
  final List<String> roles;

  @override
  bool operator ==(Object other) =>
      other is ViewerMentionTargets &&
      other.username == username &&
      listEquals(other.roles, roles);

  @override
  int get hashCode => Object.hash(username, Object.hashAll(roles));
}

final viewerMentionTargetsProvider = Provider.autoDispose<ViewerMentionTargets>(
  (ref) {
    final selfId = ref.watch(sessionProvider.select((s) => s.tokens?.userId));
    final members = ref.watch(membersProvider).valueOrNull ?? const [];
    for (final member in members) {
      if (member.id == selfId) {
        return ViewerMentionTargets(
          username: member.username,
          roles: member.roles,
        );
      }
    }
    return const ViewerMentionTargets();
  },
);

/// True when [content] names the viewer: `@username`, `@everyone`, `@here` or one of their `@[Role]`s.
bool contentMentionsViewer(String content, ViewerMentionTargets viewer) {
  for (final match in _token.allMatches(content)) {
    final name = (match.group(1) ?? match.group(2))!.toLowerCase();
    if (match.group(1) == null) {
      if (viewer.roles.any((r) => r.toLowerCase() == name)) return true;
    } else if (name == 'everyone' ||
        name == 'here' ||
        name == viewer.username?.toLowerCase()) {
      return true;
    }
  }
  return false;
}

final _token = RegExp(r'(?<![\w.@])@(?:([A-Za-z0-9_.-]+)|\[([^\]\n]+)\])');
