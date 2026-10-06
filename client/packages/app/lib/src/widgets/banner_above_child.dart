// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A banner slot above a child that must not remount when the banner comes
/// and goes.
library;

import 'package:flutter/material.dart';

/// Shows [banner] above [child], or nothing above it while [banner] is null.
///
/// The tree is the same either way, so the child keeps its element and state
/// (scroll offsets, composer text, open drawers) across the banner appearing
/// and being dismissed. An empty slot reserves no space, and the child only
/// loses its top padding while a banner is covering it.
class BannerAboveChild extends StatelessWidget {
  const BannerAboveChild({
    super.key,
    required this.banner,
    required this.child,
  });

  final Widget? banner;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        banner ?? const SizedBox.shrink(),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: banner != null,
            child: child,
          ),
        ),
      ],
    );
  }
}
