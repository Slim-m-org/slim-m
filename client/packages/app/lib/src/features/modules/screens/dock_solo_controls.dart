// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How a dock's call row carries the controls that are not part of every call:
/// the music button while alone, and the canvas toggle beside it.
///
/// Controls never shrink to make room, so when the row would overflow the
/// extras fold into a row of their own above it, the shape `VoiceCallDock`
/// already used for the canvas toggle alone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../voice/providers/call_solo.dart';
import '../../voice/providers/camera_switch.dart';
import '../../voice/providers/voice_controller.dart';
import '../../voice/providers/voice_flags.dart';
import '../../voice/screens/hold_music_dock_toggle.dart';
import '../../voice/widgets/voice_call_controls.dart';

/// One slot's width: the button with its focus-ring reserve, plus the gap before it.
double dockExtraExtent(BuildContext context) {
  final touch = AppTouchTargets.of(context);
  final hitTarget = touch ? AppSizes.rowTouch : AppSizes.rowPointer;
  final chip = AppSizes.controlMd > hitTarget ? AppSizes.controlMd : hitTarget;
  return chip + 2 * (focusRingGap + focusRingWidth) + AppSpacing.s8;
}

/// The extras in one widget, or null when there are none.
Widget? dockExtras({required bool alone, Widget? toggle}) {
  if (!alone) return toggle;
  if (toggle == null) return const HoldMusicDockToggle();
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const HoldMusicDockToggle(),
      const SizedBox(width: AppSpacing.s8),
      toggle,
    ],
  );
}

/// The card rows for a call: the call row with [toggle] and the music button
/// inline when [width] allows, otherwise those extras in a row of their own.
List<Widget> callRowsWithExtras(
  BuildContext context,
  WidgetRef ref, {
  required double width,
  required VoiceController controller,
  required VoiceFlags voice,
  Widget? toggle,
  int toggleSlots = 1,
}) {
  final alone = ref.watch(callAloneProvider);
  final extras = dockExtras(alone: alone, toggle: toggle);
  Widget callRow(Widget? extra, {bool tight = false}) => CallControls(
    controller: controller,
    voice: voice,
    extraControl: extra,
    tight: tight,
  );
  final switchCameraShown =
      voice.cameraEnabled && canSwitchCamera(ref, controller);
  bool fitsWith(int extraCount) => callRowFits(
    context,
    width,
    switchCameraShown: switchCameraShown,
    extraCount: extraCount,
  );
  // Nothing narrower than the bare row can fold away, so it spills over two lines instead.
  if (!fitsWith(0)) return [callRow(extras, tight: true)];
  if (extras == null) return [callRow(null)];
  final fits = fitsWith((alone ? 1 : 0) + (toggle != null ? toggleSlots : 0));
  return fits ? [callRow(extras)] : [Center(child: extras), callRow(null)];
}

/// Whether the call row plus [extraCount] extra buttons fit one line at [width],
/// mirroring [CallDockButton]'s own fixed-size formula rather than measuring
/// real render objects - cheap, and exact, since every control here draws at
/// one of exactly two sizes and nothing here ever wraps text.
///
/// Every button sits inside an [AppFocusRing], whose own `Container` adds
/// `focusRingGap` padding plus its border's own `focusRingGap.dimensions` on
/// every edge, reserved whether or not the ring is drawn - the same
/// measured-not-assumed extra `voice_call_controls_density_test.dart`
/// already found for this same chip.
///
/// [FloatingDockCard]'s own `Container` costs an extra 2dp beyond its
/// declared padding too, for the identical reason: `Border.all()`'s default
/// 1dp width is itself `BoxDecoration.padding`, added on top rather than
/// painted over the declared padding.
bool callRowFits(
  BuildContext context,
  double width, {
  required bool switchCameraShown,
  required int extraCount,
}) {
  final touch = AppTouchTargets.of(context);
  final hitTarget = touch ? AppSizes.rowTouch : AppSizes.rowPointer;
  final chip = AppSizes.controlMd > hitTarget ? AppSizes.controlMd : hitTarget;
  final button = chip + 2 * (focusRingGap + focusRingWidth);
  // mic, deafen, camera, [switch camera], share, leave, and the extras.
  final controlCount = (switchCameraShown ? 6 : 5) + extraCount;
  const cardPadding = AppSpacing.s12 * 2 + 2;
  // The divider before leave takes the place of one gap: s4, 1dp, s4.
  const leaveDivider = 1.0;
  // Measured, not derived: each caret's width less what its primary half gives back, at pointer density only; the mic and share both carry one.
  final carets = touch ? 0.0 : 2 * AppSpacing.s24;
  final needed =
      carets +
      controlCount * button +
      (controlCount - 1) * AppSpacing.s8 +
      leaveDivider +
      cardPadding;
  return needed <= width;
}
