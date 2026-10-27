// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Inherited markers that change how an [AppListRow] below them draws.
library;

import 'package:flutter/material.dart';

import '../../app_metrics.dart';

/// Marks rows that sit edge to edge inside a settings card: taller, inset by
/// the card's own padding, and square, so the card's hairlines and a row's
/// hover fill both run the card's full width.
class AppCardRowScope extends InheritedWidget {
  const AppCardRowScope({required super.child, super.key});

  /// The least height of a row in a card, the design's 56.
  static const double minHeight = 56;

  /// A row's own horizontal inset in a card.
  static const double inset = AppSpacing.s16;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppCardRowScope>() != null;

  @override
  bool updateShouldNotify(AppCardRowScope oldWidget) => false;
}

/// Reads every [AppListRow] label below it in `text-primary` at rest, for a
/// settings card where each label names a control rather than a destination.
class AppStrongLabelScope extends InheritedWidget {
  const AppStrongLabelScope({required super.child, super.key});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppStrongLabelScope>() != null;

  @override
  bool updateShouldNotify(AppStrongLabelScope oldWidget) => false;
}

/// Marks a subtree whose selection marker is drawn by an ancestor, so the
/// rows inside it do not draw their own.
///
/// The channel rail owns one accent bar that slides between rows, which is
/// the whole point of it travelling. An [AppListRow] inside that layer still
/// wants everything else `selected` gives it - the soft fill, the weight -
/// and wants exactly one bar, not its own on top of the layer's. Without
/// this the rail drew two, and had since the travelling marker landed.
class AppSelectionMarkerScope extends InheritedWidget {
  const AppSelectionMarkerScope({required super.child, super.key});

  /// Whether something above [context] is already drawing the marker.
  static bool ownedAbove(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppSelectionMarkerScope>() !=
      null;

  @override
  bool updateShouldNotify(AppSelectionMarkerScope oldWidget) => false;
}
