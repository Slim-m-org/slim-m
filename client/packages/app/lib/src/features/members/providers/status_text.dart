// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The typed status line and the one line under a name, from one place for
/// every surface that shows them.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'member_presence.dart';
import 'presence_activity.dart';
import '../../../providers/providers.dart';

/// Whose typed status to resolve, with the roster's copy of it to fall back
/// on when nothing fresher is known.
typedef StatusTextKey = ({String userId, String? snapshot});

/// The typed status line for one person, the same on every surface: a live
/// edit wins, then the signed-in user's own profile, then the [snapshot] the
/// caller paged in. An empty line is no line.
final statusTextProvider = Provider.autoDispose.family<String?, StatusTextKey>((
  ref,
  key,
) {
  final edited = ref.watch(
    memberProfileOverridesProvider.select((m) => m[key.userId]),
  );
  final isSelf = ref.watch(sessionProvider).tokens?.userId == key.userId;
  final own = isSelf
      ? ref.watch(meProvider.select((me) => me.valueOrNull))
      : null;
  final text = edited != null
      ? edited.statusText
      : own != null
      ? own.statusText
      : key.snapshot;
  return text == null || text.isEmpty ? null : text;
});

/// The one line under a member's name: what they are doing wins over what they
/// typed.
String? personLine(api.PresenceActivity? activity, String? statusText) =>
    activity == null ? statusText : describeActivity(activity);
