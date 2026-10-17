// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What each member is listening to or playing, as this connection is told.
///
/// Kept apart from [PresenceController]'s status map so a track change
/// rebuilds only the rows and cards that show one. An absent id means no
/// activity is visible, which is also what a hidden or offline member reads
/// as: the server never sends one for them.
library;

import 'package:flutter/widgets.dart' show IconData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart' show AppIcons;

class PresenceActivityController
    extends StateNotifier<Map<String, api.PresenceActivity>> {
  PresenceActivityController() : super(const {});

  /// Sets or clears one member's activity. `PresenceController` feeds this
  /// from the live socket, so this holds no subscription of its own.
  void apply(String userId, api.PresenceActivity? activity) {
    if (!mounted || state[userId] == activity) return;
    final next = {...state};
    if (activity == null) {
      next.remove(userId);
    } else {
      next[userId] = activity;
    }
    state = next;
  }

  /// Applies a batch lookup: every id it names is now exactly as told.
  void applyBatch(Iterable<api.PresenceStatus> statuses) {
    for (final status in statuses) {
      apply(status.userId, status.activity);
    }
  }

  /// Forgets everything, for a session ending.
  void clear() {
    if (mounted) state = const {};
  }
}

final presenceActivityProvider =
    StateNotifierProvider<
      PresenceActivityController,
      Map<String, api.PresenceActivity>
    >((ref) => PresenceActivityController());

/// One member's visible activity, scoped so other members' changes do not
/// rebuild the watcher.
final memberActivityProvider = Provider.autoDispose
    .family<api.PresenceActivity?, String>(
      (ref, userId) =>
          ref.watch(presenceActivityProvider.select((m) => m[userId])),
    );

/// "Listening to Title - Artist", or "Playing Title".
String describeActivity(api.PresenceActivity activity) {
  final verb = switch (activity.kind) {
    api.ActivityKind.listening => 'Listening to',
    api.ActivityKind.playing => 'Playing',
  };
  final subtitle = activity.subtitle;
  return subtitle == null
      ? '$verb ${activity.title}'
      : '$verb ${activity.title} - $subtitle';
}

/// "Listening on Spotify", "Listening", or "Playing": the line above the
/// title, naming the reporting player when it said so.
String activityHeading(api.PresenceActivity activity) {
  final verb = switch (activity.kind) {
    api.ActivityKind.listening => 'Listening',
    api.ActivityKind.playing => 'Playing',
  };
  final source = activity.source;
  return source == null ? verb : '$verb on $source';
}

/// The Lucide glyph for a kind of activity.
IconData activityIcon(api.ActivityKind kind) => switch (kind) {
  api.ActivityKind.listening => AppIcons.listening,
  api.ActivityKind.playing => AppIcons.playing,
};
