// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Leaving a screen that may be a modal.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

/// Closes this screen: pops the modal it is shown in, or falls back to
/// replacing the route when it was opened cold from a pasted URL and so has
/// nothing to pop back to.
void closeScreen(BuildContext context, String fallback) {
  if (Navigator.of(context).canPop()) {
    Navigator.of(context).pop();
    return;
  }
  context.go(fallback);
}

/// Asks the person; true lets the route go.
typedef RouteLeaveCheck = Future<bool> Function();

final _leaveChecks = Expando<List<RouteLeaveCheck>>('route leave checks');

/// Asks [check] before an on-screen back control leaves [route].
///
/// A [PopScope] only hears a system back; the app-bar arrow and in-screen
/// backs close without popping through it, so they ask these instead.
void addRouteLeaveCheck(Route<Object?> route, RouteLeaveCheck check) =>
    (_leaveChecks[route] ??= []).add(check);

void removeRouteLeaveCheck(Route<Object?> route, RouteLeaveCheck check) =>
    _leaveChecks[route]?.remove(check);

/// True when every check on this context's route lets it go, asking each in turn.
Future<bool> routeLetsGo(BuildContext context) async {
  final route = ModalRoute.of(context);
  if (route == null) return true;
  for (final check in [...?_leaveChecks[route]]) {
    if (!await check()) return false;
  }
  return true;
}

/// [closeScreen] once every draft on this route lets it go.
Future<void> leaveScreen(BuildContext context, String fallback) async {
  if (!await routeLetsGo(context) || !context.mounted) return;
  closeScreen(context, fallback);
}

/// The app-bar leading button for a screen that [leaveScreen] closes.
///
/// Eight screens carried the identical five-line `IconButton` around this
/// call; naming it once means a change to the back affordance is one edit,
/// and no screen can drift into a different glyph or a missing tooltip.
///
/// [AppIconButton] rather than Material's own: a raw `IconButton` in an app
/// bar draws Material's circular hover overlay, which is far larger than the
/// glyph and than every other control in this app, and read as a grey disc
/// swallowing the arrow on desktop.
class BackToButton extends StatelessWidget {
  const BackToButton({
    super.key,
    required this.tooltip,
    required this.fallback,
    this.onBack,
  });

  /// Names the destination ("Back to Space settings"), not just "Back": the
  /// tooltip is the only thing that says where this goes.
  final String tooltip;

  /// Where to land when there is nothing to pop; see [closeScreen].
  final String fallback;

  /// Runs instead of [leaveScreen].
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final button = AppIconButton(
      icon: AppIcons.back,
      semanticLabel: tooltip,
      tooltip: tooltip,
      onPressed: onBack ?? () => unawaited(leaveScreen(context, fallback)),
    );
    // The 56pt leading slot cannot hold a 44pt button plus the 8pt gutter, which squeezed it to 40.
    return AppTouchTargets.of(context)
        ? Center(child: button)
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
            child: button,
          );
  }
}
