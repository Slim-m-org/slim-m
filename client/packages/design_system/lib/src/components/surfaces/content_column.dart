// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A comfortable column for a screen that is a list of settings.
///
/// The same reasoning as [kMessageColumnMax], applied to rows rather than
/// prose: a settings row puts its label at one end and its value at the other,
/// so stretched across a monitor it leaves the two 600 points apart with
/// nothing between them, and the eye has to travel the whole way to pair them
/// up. That is what makes a full-bleed settings list read as a phone screen
/// blown up rather than a desktop one.
library;

import 'package:flutter/widgets.dart';

/// How wide a settings or administration column is allowed to get.
///
/// Slightly narrower than [kMessageColumnMax]: a message is prose that gains
/// from a long measure, a row of controls does not.
const double kContentColumnMax = 720;

/// Centres [child] and stops it growing past [maxWidth].
///
/// Below that width this is a no-op, so a phone is unaffected and nothing here
/// needs to know which it is on.
class AppContentColumn extends StatelessWidget {
  const AppContentColumn({
    super.key,
    required this.child,
    this.maxWidth = kContentColumnMax,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    if (AppBoundedWidth.isBounded(context)) return child;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// Marks a surface that already bounds its own width, such as a floating
/// modal panel, so an [AppContentColumn] inside it fills the surface rather
/// than centring a narrower column with dead gutters either side.
class AppBoundedWidth extends InheritedWidget {
  const AppBoundedWidth({super.key, required super.child});

  static bool isBounded(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppBoundedWidth>() != null;

  @override
  bool updateShouldNotify(AppBoundedWidth oldWidget) => false;
}
