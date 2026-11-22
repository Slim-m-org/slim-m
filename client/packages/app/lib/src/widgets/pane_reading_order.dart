// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a screen reader reads a shell pane among its row siblings.
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

/// Reads [child] at [order] among its siblings, because geometry alone read a taller pane's header before a shorter one's whole body.
class PaneReadingOrder extends StatelessWidget {
  const PaneReadingOrder({super.key, required this.order, required this.child});

  final double order;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    explicitChildNodes: true,
    sortKey: OrdinalSortKey(order),
    child: child,
  );
}
