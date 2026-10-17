// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every SnackBar this app shows, for failures only; a success goes through
/// `toastsProvider`. Going through here applies the reduced-motion setting,
/// which a raw `showSnackBar` call skips (`reduce_motion_gate_test.dart`
/// catches one), and pads the bar clear of the call dock, reshowing it if
/// the dock appears or grows while it is up.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../features/modules/providers/dock_reservation.dart';

/// Shows [message] in a plain SnackBar.
///
/// `maybeOf` rather than `.of`: no call site's message actually depends on
/// throwing when a `ScaffoldMessenger` is missing, and one already guarded
/// against exactly that with a null check of its own.
void showAppSnackbar(BuildContext context, String message) => _showAndTrack(
  _containerOf(context),
  ScaffoldMessenger.maybeOf(context),
  reduceMotion: AppMotion.isReduced(context),
  message: message,
);

/// Null outside this app's own `ProviderScope` - `app_snackbar_test.dart`
/// pumps a bare `Scaffold` on purpose to isolate the motion behaviour this
/// file exists for, and that surface must keep working exactly as `maybeOf`
/// already lets a missing `ScaffoldMessenger` keep working: no reservation
/// and no growth-reshow, the same as before either existed.
ProviderContainer? _containerOf(BuildContext context) {
  try {
    return ProviderScope.containerOf(context, listen: false);
  } on StateError {
    return null;
  }
}

/// Matches the framework's own floating default (`EdgeInsets.fromLTRB(15, 5,
/// 15, 10)`) whenever nothing needs reserving, and only departs from it on
/// the bottom edge, the one side a dock ever shares with this snackbar.
/// Returns the controller so a caller can track when this particular show
/// closes; null exactly when nothing was shown at all.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _showOn(
  ScaffoldMessengerState? messenger, {
  required bool reduceMotion,
  required double reserveBottom,
  required String message,
}) {
  if (messenger == null) return null;
  // Margins rather than a width: a fixed width wider than a phone has no room left for its sides.
  final screen = MediaQuery.sizeOf(messenger.context).width;
  final side = math.max(AppSpacing.s16, (screen - kSheetMaxWidth) / 2);
  // Flutter allows a margin only on a floating snackbar.
  final floating =
      Theme.of(messenger.context).snackBarTheme.behavior ==
      SnackBarBehavior.floating;
  return messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      margin: floating ? _snackbarMargin(side, reserveBottom) : null,
    ),
    snackBarAnimationStyle: reduceMotion ? AnimationStyle.noAnimation : null,
  );
}

EdgeInsets _snackbarMargin(double side, double reserveBottom) {
  final bottom = reserveBottom > 0
      ? reserveBottom + AppSpacing.s16
      : AppSpacing.s8;
  return EdgeInsets.fromLTRB(side, AppSpacing.s4, side, bottom);
}

/// Shows, then - when a [container] is available - hands the snackbar to
/// [_snackbarDockGrowthProvider] so a dock that appears or grows while it
/// is still up gets it reshown with a fresh margin.
void _showAndTrack(
  ProviderContainer? container,
  ScaffoldMessengerState? messenger, {
  required bool reduceMotion,
  required String message,
}) {
  final reserveBottom = container?.read(bottomDockReservationProvider) ?? 0;
  final controller = _showOn(
    messenger,
    reduceMotion: reduceMotion,
    reserveBottom: reserveBottom,
    message: message,
  );
  if (controller == null || container == null) return;
  final tracked = _TrackedSnackbar(
    messenger: messenger!,
    reduceMotion: reduceMotion,
    message: message,
  );
  final growth = container.read(_snackbarDockGrowthProvider.notifier);
  growth.track(tracked);
  controller.closed.then((_) => growth.clear(tracked));
}

class _TrackedSnackbar {
  _TrackedSnackbar({
    required this.messenger,
    required this.reduceMotion,
    required this.message,
  });

  final ScaffoldMessengerState messenger;
  final bool reduceMotion;
  final String message;
}

/// Reshows the most recently tracked snackbar, with a fresh margin,
/// whenever `bottomDockReservationProvider` grows past what it read the
/// last time anything here showed or reshowed. See this file's own library
/// doc for why a shrink is deliberately not handled the same way.
class _SnackbarDockGrowth extends Notifier<void> {
  _TrackedSnackbar? _active;

  @override
  void build() {
    ref.listen<double>(bottomDockReservationProvider, _onReservationChanged);
  }

  void track(_TrackedSnackbar snackbar) => _active = snackbar;

  void clear(_TrackedSnackbar snackbar) {
    if (identical(_active, snackbar)) _active = null;
  }

  void _onReservationChanged(double? previous, double next) {
    final active = _active;
    if (active == null || next <= (previous ?? 0)) return;
    _active = null;
    active.messenger.removeCurrentSnackBar();
    final controller = _showOn(
      active.messenger,
      reduceMotion: active.reduceMotion,
      reserveBottom: next,
      message: active.message,
    );
    if (controller == null) return;
    final reshown = _TrackedSnackbar(
      messenger: active.messenger,
      reduceMotion: active.reduceMotion,
      message: active.message,
    );
    track(reshown);
    controller.closed.then((_) => clear(reshown));
  }
}

final _snackbarDockGrowthProvider = NotifierProvider<_SnackbarDockGrowth, void>(
  _SnackbarDockGrowth.new,
);
