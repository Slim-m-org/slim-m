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

import '../../../audio/hold_music_player.dart' show holdMusicAvailableProvider;
import '../../../widgets/control_swatch_row.dart' show ControlOptionEntry;
import '../../voice/providers/call_solo.dart';
import '../../voice/providers/camera_switch.dart';
import '../../voice/providers/hold_music_actions.dart';
import '../../voice/providers/voice_controller.dart';
import '../../voice/providers/voice_flags.dart';
import '../../voice/screens/hold_music_dock_toggle.dart';
import '../../voice/widgets/voice_call_controls.dart';

/// Whether the music button belongs in the dock: alone in the call and too narrow for the floating badge.
bool soloMusicInDock(BuildContext context, WidgetRef ref) =>
    ref.watch(holdMusicAvailableProvider) &&
    ref.watch(callAloneProvider) &&
    !holdMusicBadgeFits(context);

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

/// What [callRowsWithExtras] lays out beside the call row.
class CallRowOptions {
  const CallRowOptions({
    required this.width,
    required this.controller,
    required this.voice,
    this.toggle,
    this.toggleSlots = 1,
    this.toggleMenu = const [],
    this.spillRow = false,
  });

  final double width;
  final VoiceController controller;
  final VoiceFlags voice;
  final Widget? toggle;
  final int toggleSlots;
  final List<ControlOptionEntry> toggleMenu;
  final bool spillRow;
}

/// The card rows for a call: the call row with [toggle] and the music button
/// inline when [width] allows, otherwise folded into the mic menu ([toggleMenu]
/// is the toggle's own menu rows) or, with no menu rows, in a row of their own.
/// [spillRow] skips the menu: the extras always get that row of their own, so they stay visible.
List<Widget> callRowsWithExtras(
  BuildContext context,
  WidgetRef ref,
  CallRowOptions options,
) {
  final CallRowOptions(
    :width,
    :controller,
    :voice,
    :toggle,
    :toggleSlots,
    :toggleMenu,
    :spillRow,
  ) = options;
  final alone = soloMusicInDock(context, ref);
  final extras = dockExtras(alone: alone, toggle: toggle);
  Widget callRow(
    Widget? extra, {
    bool tight = false,
    List<ControlOptionEntry> menuExtras = const [],
  }) => CallControls(
    controller: controller,
    voice: voice,
    extraControl: extra,
    tight: tight,
    menuExtras: menuExtras,
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
  if (fits) return [callRow(extras)];
  if (spillRow) {
    return [Center(child: extras), callRow(null)];
  }
  // The one rule of desktop-vs-mobile.md: width decides, so extras fold into the mic menu.
  final music = alone
      ? holdMusicMenuOptions(ref)
      : const <ControlOptionEntry>[];
  if (toggleMenu.isNotEmpty) {
    return [
      callRow(null, menuExtras: [...music, ...toggleMenu]),
    ];
  }
  if (alone && fitsWith(toggle != null ? toggleSlots : 0)) {
    return [callRow(toggle, menuExtras: music)];
  }
  return [
    ?toggle == null ? null : Center(child: toggle),
    callRow(null, menuExtras: music),
  ];
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
