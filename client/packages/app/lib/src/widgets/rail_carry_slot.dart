// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a carried rail item leaves behind: a quiet empty slot the size of its
/// face. The row itself is not drawn, so its selection bar, kebab, hover tint
/// and focus ring appear once, on the lifted copy, and never twice.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class RailCarrySlot extends StatelessWidget {
  const RailCarrySlot({super.key, required this.height, this.inset = 0});

  final double height;

  /// The gap the real row keeps from the rail's left edge.
  final double inset;

  static const _opacity = 0.35;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: EdgeInsets.only(left: inset),
      child: SizedBox(
        height: height,
        child: Opacity(
          opacity: _opacity,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.surfaceRaised,
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
          ),
        ),
      ),
    );
  }
}
