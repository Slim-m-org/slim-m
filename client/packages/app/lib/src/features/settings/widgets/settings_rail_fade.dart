// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Fades the bottom of the settings rail while rows sit below it, so a row the
/// list cuts off reads as more to scroll to rather than as a broken layout.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class SettingsRailFade extends StatefulWidget {
  const SettingsRailFade({super.key, required this.child});

  final Widget child;

  @override
  State<SettingsRailFade> createState() => _SettingsRailFadeState();
}

class _SettingsRailFadeState extends State<SettingsRailFade> {
  bool _moreBelow = false;

  bool _onMetrics(ScrollMetrics metrics) {
    final moreBelow = metrics.extentAfter > 0.5;
    if (moreBelow != _moreBelow) setState(() => _moreBelow = moreBelow);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Stack(
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (n) => _onMetrics(n.metrics),
          child: NotificationListener<ScrollUpdateNotification>(
            onNotification: (n) => _onMetrics(n.metrics),
            child: widget.child,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: AppSpacing.s32,
          child: IgnorePointer(
            child: AnimatedOpacity(
              key: const ValueKey('settings-rail-fade'),
              opacity: _moreBelow ? 1 : 0,
              duration: AppMotion.reduced(context, AppMotion.fast),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      tokens.surfaceSunken.withValues(alpha: 0),
                      tokens.surfaceSunken,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
