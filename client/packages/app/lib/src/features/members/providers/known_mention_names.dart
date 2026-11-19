// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The usernames and role names a mention in a message can be matched against.
library;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

/// The usernames a mention can be matched against, read from the member
/// roster [members].
///
/// `valueOrNull`, never `maybeWhen(data:)`: an `AsyncError` keeps whatever
/// resolved before it, and only the first of those two can see that value.
/// Reading it the other way made a failed fetch indistinguishable from an
/// empty deployment, so every `@name` in view fell back to plain text the
/// moment the connection dropped (reported 2026-08-13, "mentions also get
/// unhighlighted when the server was offline").
///
/// A cold start with no connection genuinely has nothing to match against and
/// still renders mentions plain; that is the honest answer rather than a gap,
/// since nothing has ever told this client who the members are.
Set<String> knownUsernamesFrom(AsyncValue<List<api.UserProfile>> members) =>
    _usernameMemo.of(members.valueOrNull);

final _usernameMemo = _SetMemo(
  (list) => list.map((m) => m.username.toLowerCase()).toSet(),
);

/// Hands back the previous set while the roster it was built from is the same
/// list or yields equal names, so a watcher selecting on it sees no change.
class _SetMemo {
  _SetMemo(this._build);

  final Set<String> Function(List<api.UserProfile> members) _build;
  List<api.UserProfile>? _source;
  Set<String> _last = const <String>{};

  Set<String> of(List<api.UserProfile>? members) {
    if (members == null) return const <String>{};
    if (identical(members, _source)) return _last;
    final next = _build(members);
    _source = members;
    if (!setEquals(next, _last)) _last = next;
    return _last;
  }
}

/// The role names an `@[Role Name]` mention can be matched against, read the
/// same `valueOrNull` way [knownUsernamesFrom] is for the identical reason:
/// a failed refresh must not unhighlight a role mention that was already on
/// screen. Derived from [members]'s own `roles` field (`GET /members`,
/// requiring no permission beyond viewing the roster) rather than a
/// dedicated roles listing, which stays MANAGE_ROLES-gated - so a role
/// nobody currently visible holds is not offered here, the same boundary
/// the member-badge feature this reuses already draws.
Set<String> knownRoleNamesFrom(AsyncValue<List<api.UserProfile>> members) =>
    _roleMemo.of(members.valueOrNull);

final _roleMemo = _SetMemo(
  (list) =>
      list.expand((m) => m.roles).map((name) => name.toLowerCase()).toSet(),
);
