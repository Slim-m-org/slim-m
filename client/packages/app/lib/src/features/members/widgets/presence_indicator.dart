// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A free-standing presence dot, for the places a state is offered rather than
/// reported (the status menu). Everywhere a person is drawn, the dot is part
/// of their `UserAvatar`.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// [presence] as its dot, or nothing at all while it is unknown.
class PresenceIndicator extends StatelessWidget {
  const PresenceIndicator({
    super.key,
    required this.presence,
    this.backgroundColor,
    this.size = 10,
  });

  final AppPresence presence;

  /// What the dot sits on, when that is not the base surface.
  final Color? backgroundColor;
  final double size;

  @override
  Widget build(BuildContext context) => presence == AppPresence.unknown
      ? const SizedBox.shrink()
      : AppStatusDot(
          status: presence,
          size: size,
          backgroundColor: backgroundColor,
        );
}
