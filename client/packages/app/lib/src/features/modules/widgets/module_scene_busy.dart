// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The in-flight indicator a module scene shows over its own play surface.
///
/// Split out of `module_scene_view.dart` when adding it pushed that file past
/// the review ceiling, the same reason `module_scene_controls.dart` and its
/// siblings already exist.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// `ModuleSceneView._send` already drops a tap while busy (its own
/// debounce), so without this a tap simply looked like nothing happened
/// until the module's response, or its wall-clock cap, finally landed.
///
/// Unmounted rather than merely faded to zero opacity while idle: an
/// indeterminate [CircularProgressIndicator] animates forever, and the scene
/// already runs `play`'s own timer, so a second ticker with nothing to show
/// for it is a cost this pays for free by only building the spinner while busy.
class SceneBusyIndicator extends StatelessWidget {
  const SceneBusyIndicator({
    super.key,
    required this.busy,
    required this.tokens,
  });

  final bool busy;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedSwitcher(
      duration: AppMotion.base,
      child: busy
          ? Semantics(
              key: const ValueKey('busy'),
              label: 'Working',
              liveRegion: true,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: tokens.surfaceRaised,
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(AppSpacing.s4),
                  child: SizedBox(
                    width: AppSizes.icon16,
                    height: AppSizes.icon16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            )
          : const SizedBox.shrink(key: ValueKey('idle')),
    ),
  );
}
