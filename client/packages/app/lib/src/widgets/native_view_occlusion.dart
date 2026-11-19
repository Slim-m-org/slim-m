// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A native view (the desktop video panel's webview) paints above all of
/// Flutter, so it steps aside while a floating Flutter surface is open.
library;

import 'package:flutter/widgets.dart';

/// How many floating surfaces are open right now; a native view hides while
/// this is above zero.
final ValueNotifier<int> openFloatingSurfaces = ValueNotifier(0);

/// Counts as an open floating surface for as long as it is mounted.
class OccludesNativeViews extends StatefulWidget {
  const OccludesNativeViews({super.key, required this.child});

  final Widget child;

  @override
  State<OccludesNativeViews> createState() => _OccludesNativeViewsState();
}

class _OccludesNativeViewsState extends State<OccludesNativeViews> {
  @override
  void initState() {
    super.initState();
    openFloatingSurfaces.value++;
  }

  @override
  void dispose() {
    openFloatingSurfaces.value--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
