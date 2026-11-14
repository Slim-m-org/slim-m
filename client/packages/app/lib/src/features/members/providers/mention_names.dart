// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The name a `@username` mention reads as in this space.
library;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'member_presence.dart';

/// Lower-cased username to the member's name here (nickname, else account
/// name), left out where it is the username itself. [live] holds the
/// profiles edited since the roster was fetched, which win over it.
///
/// `valueOrNull` for the same reason mention highlighting uses it: a failed
/// refresh must not change what is already on screen.
Map<String, String> mentionNamesFrom(
  AsyncValue<List<api.UserProfile>> members, {
  Map<String, api.UserProfile> live = const {},
}) => _memo.of(members.valueOrNull, live);

/// Stable between rosters that yield equal names, so message runs do not
/// rebuild on every presence or role change.
final mentionNamesProvider = Provider.autoDispose<Map<String, String>>(
  (ref) => mentionNamesFrom(
    ref.watch(membersProvider),
    live: ref.watch(memberProfileOverridesProvider),
  ),
);

final _memo = _NamesMemo();

class _NamesMemo {
  List<api.UserProfile>? _source;
  Map<String, api.UserProfile>? _live;
  Map<String, String> _last = const {};

  Map<String, String> of(
    List<api.UserProfile>? members,
    Map<String, api.UserProfile> live,
  ) {
    if (members == null) return const {};
    if (identical(members, _source) && identical(live, _live)) return _last;
    final next = <String, String>{
      for (final m in members.map((m) => live[m.id] ?? m))
        if (m.displayName.trim().isNotEmpty && m.displayName != m.username)
          m.username.toLowerCase(): m.displayName,
    };
    _source = members;
    _live = live;
    if (!mapEquals(next, _last)) _last = next;
    return _last;
  }
}
