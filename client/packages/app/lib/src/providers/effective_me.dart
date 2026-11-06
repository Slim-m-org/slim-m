// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The signed-in caller's own profile.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import 'live_events.dart';
import 'providers.dart';

/// The caller's own profile. Real endpoint; kept here rather than beside one
/// particular widget because more than one of them (the rail footer, the
/// member pane's "message a member" affordance) need to know their own id.
final meProvider = FutureProvider.autoDispose<Me>(
  (ref) => ref.watch(apiProvider).me(),
);

/// [meProvider]'s answer, holding the last one that actually resolved while
/// the connection is down, and refetched when the caller edits their profile
/// somewhere else.
///
/// [meProvider] is fetched once per session. Other people's profiles are kept
/// current by `BatchProfilesController` and `MemberProfileOverridesController`,
/// both watching `ProfileChanged`; nothing watched it for the caller, so a
/// picture or name set on a phone left every other device drawing the old one
/// until it restarted - an avatar is cached under `avatarUpdatedAt`, which
/// only a refetch moves.
///
/// Losing the network made this read as null, and a null `Me` is
/// indistinguishable from a member holding no permissions at all - so the
/// channel rail reshaped itself the moment a phone lost signal: empty
/// categories vanished (they render only for a manager), every row's manage
/// kebab went with them, and the reorderable list collapsed to a plain
/// column. Reported 2026-08-13 as "channels format weird, colors change" when
/// there is no connection to the server.
///
/// Keeping the last resolved answer is safe rather than a shortcut, and
/// `schema/openapi.yaml` already says why: this bitmask is a UI nicety, and
/// the server re-authorizes every write regardless, so a stale-but-real
/// answer can only ever offer an action the server then refuses - where
/// answering null hides actions the caller genuinely holds.
///
/// Cached per user, never across one: a sign-out must not leave the next
/// account looking at whatever the last one could do. The check is on the
/// answer's own id rather than on the fetch having succeeded, because an
/// `AsyncError` keeps whatever value resolved before it - so a failed fetch
/// under a new session still hands back the previous account's `Me`, and
/// only comparing the answer's own id against the session's catches that.
final effectiveMeProvider = NotifierProvider<EffectiveMe, Me?>(EffectiveMe.new);

class EffectiveMe extends Notifier<Me?> {
  String? _forUser;
  Me? _last;
  DateTime? _lastRetry;

  /// A failed fetch is otherwise never repeated: nothing else invalidates
  /// [meProvider] until the caller edits their own profile.
  static const retryGap = Duration(seconds: 30);

  @override
  Me? build() {
    final userId = ref.watch(sessionProvider).tokens?.userId;
    if (userId != _forUser) {
      _forUser = userId;
      _last = null;
    }
    // Own-profile edits from another device; the two controllers that do this for other people's profiles never covered the caller's own. See this provider's doc.
    final sub = ref.read(liveEventsProvider).listen((event) {
      if (event is ProfileChanged && event.userId == userId) {
        ref.invalidate(meProvider);
      } else if (userId != null) {
        _retryIfFailed();
      }
    });
    ref.onDispose(() => unawaited(sub.cancel()));

    final resolved = ref.watch(meProvider).valueOrNull;
    if (resolved != null && resolved.id == userId) _last = resolved;
    return _last;
  }

  /// Any live event means the server is reachable again, so a failed fetch is worth one more try.
  void _retryIfFailed() {
    final me = ref.read(meProvider);
    if (!me.hasError || me.isLoading) return;
    final now = DateTime.now();
    final last = _lastRetry;
    if (last != null && now.difference(last) < retryGap) return;
    _lastRetry = now;
    ref.invalidate(meProvider);
  }
}
