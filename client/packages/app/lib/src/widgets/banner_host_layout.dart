// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one shape every banner above the signed-in shell uses.
///
/// The column and the [Expanded] stay put whether or not a banner shows, so
/// [child] keeps its element and its state when one appears or goes. Only the
/// banner is conditional, and it is where the status-bar inset is spent, so a
/// hidden banner reserves no band and [child] sees the inset until one shows.
library;

import 'package:flutter/material.dart';

class BannerHostLayout extends StatelessWidget {
  const BannerHostLayout({
    super.key,
    required this.banner,
    required this.child,
  });

  final Widget? banner;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ?banner,
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
