// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one place the app pushes a modal dialog route.
///
/// With Flutter's `windowing` flag on, which the Linux and Windows builds enable
/// for the pop-out, `showDialog` opens a native OS window and drops its route builder,
/// so every sheet, select and picker became a floating window. Pushing
/// [DialogRoute] directly keeps them inside the main window. Nothing else in
/// `client/packages/*/lib` may call `showDialog`; a gate enforces it.
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

import '../../app_motion.dart';

/// Whether this build turns Flutter's windowing on, so `showDialog` would open
/// an OS window; elsewhere it stays reachable (see [showInWindowDialog]).
bool get buildsWithWindowing =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows);

/// Pushes [builder] as an in-window Material dialog on the root navigator.
///
/// Only the Linux and Windows builds turn windowing on, so other platforms keep
/// calling Flutter's `showDialog`: with no call to it the macOS AOT build
/// crashed the snapshot generator ("Class with illegal cid",
/// `_window_macos.dart`) in 0.91.0.
Future<T?> showInWindowDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  AnimationStyle? animationStyle,
  RouteSettings? routeSettings,
}) {
  if (!buildsWithWindowing) {
    return showDialog<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
      animationStyle: animationStyle,
      routeSettings: routeSettings,
      useRootNavigator: true,
    );
  }
  final navigator = Navigator.of(context, rootNavigator: true);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  return navigator.push<T>(
    DialogRoute<T>(
      context: context,
      builder: builder,
      themes: themes,
      barrierColor: DialogTheme.of(context).barrierColor ??
          Theme.of(context).dialogTheme.barrierColor ??
          Colors.black54,
      barrierDismissible: barrierDismissible,
      settings: routeSettings,
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      animationStyle: animationStyle,
    ),
  );
}

/// [showTimePicker], kept in-window: Flutter's own calls `showDialog`.
Future<TimeOfDay?> showAppTimePicker({
  required BuildContext context,
  required TimeOfDay initialTime,
}) {
  return showInWindowDialog<TimeOfDay>(
    context: context,
    animationStyle:
        AppMotion.isReduced(context) ? AnimationStyle.noAnimation : null,
    builder: (_) => TimePickerDialog(initialTime: initialTime),
  );
}
