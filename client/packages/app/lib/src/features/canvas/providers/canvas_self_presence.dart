// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the caller's own camera bubble is shown on the Voice Canvas at
/// all - a standing, device-wide "never show my own camera" choice, kept
/// distinct from where any one tile sits right now.
///
/// Position, size and per-call lock/hide for every tile - self, remote,
/// camera or screen share - live in `CanvasPresenceTileOverrides` instead
/// (`canvas_presence_layer.dart`'s own doc explains why): that state is
/// personal to one call and is meant to reset when the call does. This
/// preference is the opposite shape on purpose - it answers "would I ever
/// want to see myself on a canvas" once, and that answer should survive a
/// relaunch the way `themeControllerProvider` and the voice settings keys
/// already do (`providers.dart`'s own doc names them), not the per-account
/// namespacing `personal_space_visibility.dart` needs: there is nothing
/// account-specific to leak by sharing it across every account on this
/// device.
///
/// Used to also hold which of the pane's four corners a self bubble rested
/// in; removed once the bubble moved into world space and stopped resting
/// in a screen corner at all.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// The `SharedPreferences` key, in [preferencesProvider], following the
/// existing `slimm.<area>.<thing>` convention.
const canvasSelfBubbleHiddenKey = 'slimm.canvas.self_bubble.hidden';

class CanvasSelfPresenceState {
  const CanvasSelfPresenceState({this.hidden = false});

  final bool hidden;

  CanvasSelfPresenceState copyWith({bool? hidden}) =>
      CanvasSelfPresenceState(hidden: hidden ?? this.hidden);
}

class CanvasSelfPresenceController
    extends StateNotifier<CanvasSelfPresenceState> {
  CanvasSelfPresenceController(this._ref)
    : super(const CanvasSelfPresenceState()) {
    ready = _load();
  }

  final Ref _ref;

  /// Bumped by every explicit [setHidden] call, so a load still in flight
  /// when the very first one of those lands does not clobber it back to
  /// whatever was on disk before that write finished - the same generation
  /// guard `personal_space_visibility.dart`'s own controller carries for the
  /// identical shape of race.
  int _generation = 0;

  /// Resolves once the persisted state, if any, has been read. Exposed so a
  /// caller modelling a relaunch - this controller is rebuilt fresh every
  /// time the canvas pane reopens - can wait for exactly that, rather than
  /// guessing how many event-loop turns a `SharedPreferences` round trip
  /// takes.
  late final Future<void> ready;

  Future<void> _load() async {
    final generation = _generation;
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      if (!mounted || generation != _generation) return;
      state = CanvasSelfPresenceState(
        hidden: prefs.getBool(canvasSelfBubbleHiddenKey) ?? false,
      );
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.ui,
        'Could not read the canvas cursor setting; showing it',
        error,
        stack,
      );
    }
  }

  /// Hides the bubble; reversed by calling this again with `false`, which is
  /// exactly what the canvas overflow menu's own toggle item does - there is
  /// no separate "show" method to keep in step with it.
  Future<void> setHidden(bool hidden) async {
    await ready;
    _generation++;
    state = state.copyWith(hidden: hidden);
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      await prefs.setBool(canvasSelfBubbleHiddenKey, hidden);
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.ui,
        'Could not save the canvas cursor setting; applied for this session only',
        error,
        stack,
      );
    }
  }
}

/// Deliberately not `autoDispose`: the canvas pane is torn down and rebuilt
/// every time it opens and closes (see `canvas_pane.dart`'s own module doc),
/// and disposing this alongside it would re-run the async load on every
/// reopen, flashing the bubble back to visible before the stored value loads
/// back in.
final canvasSelfPresenceProvider =
    StateNotifierProvider<
      CanvasSelfPresenceController,
      CanvasSelfPresenceState
    >((ref) => CanvasSelfPresenceController(ref));
