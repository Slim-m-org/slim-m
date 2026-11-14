// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The status and navigation bars, drawn over the page instead of beside it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Transparent bars with icons that contrast with [theme]. Android 14 and
/// older paint an opaque launch-theme bar unless told otherwise, which showed
/// as a grey strip over a light page; Android 15 always draws edge to edge.
SystemUiOverlayStyle systemBarsFor(Brightness theme) {
  final icons = theme == Brightness.dark ? Brightness.light : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: icons,
    statusBarBrightness: theme,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarContrastEnforced: false,
    systemNavigationBarIconBrightness: icons,
  );
}

/// Lets the page draw under both bars; the overlay style above colours them.
Future<void> drawUnderSystemBars() =>
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
