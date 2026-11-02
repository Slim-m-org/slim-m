// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The raised surface every control laid over a video sits on, so it reads
/// against any picture and the strip, the volume and full screen look alike.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class StreamControlPill extends StatelessWidget {
  const StreamControlPill({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: tokens.borderSubtle),
      ),
      child: child,
    );
  }
}
