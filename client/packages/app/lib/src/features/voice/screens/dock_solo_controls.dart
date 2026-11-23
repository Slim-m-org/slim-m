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
import '../providers/call_solo.dart';
import '../providers/camera_switch.dart';
import '../providers/hold_music_actions.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import 'hold_music_dock_toggle.dart';
import '../widgets/captions_button.dart' show canUseCaptions;
import '../widgets/soundboard_button.dart' show canUseSoundboard;
import '../widgets/voice_call_controls.dart';

/// Whether the music button belongs in the dock: alone in the call and too narrow for the floating badge.
bool soloMusicInDock(BuildContext context, WidgetRef ref) {
  final available = ref.watch(holdMusicAvailableProvider);
  final alone = ref.watch(callAloneProvider);
  final badgeAside = ref.watch(holdMusicBadgeAsideProvider);
  return available && alone && (badgeAside || !holdMusicBadgeFits(context));
}

/// One dock button's width with its focus-ring reserve and the gap before it.
double dockButtonExtent(BuildContext context) {
  final touch = AppTouchTargets.of(context);
  final hitTarget = touch ? AppSizes.rowTouch : AppSizes.rowPointer;
  final chip = AppSizes.controlMd > hitTarget ? AppSizes.controlMd : hitTarget;
  return chip + 2 * (focusRingGap + focusRingWidth) + AppSpacing.s8;
}

/// The music button's width: a [dockButtonExtent] and its options caret at pointer density.
double dockExtraExtent(BuildContext context) {
  final caret = AppTouchTargets.of(context) ? 0.0 : AppSpacing.s24;
  return dockButtonExtent(context) + caret;
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
    this.hints = true,
  });

  final double width;
  final VoiceController controller;
  final VoiceFlags voice;
  final Widget? toggle;
  final int toggleSlots;
  final List<ControlOptionEntry> toggleMenu;
  final bool spillRow;

  /// See [CallControls.hints].
  final bool hints;
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
    :hints,
  ) = options;
  final alone = soloMusicInDock(context, ref);
  final extras = dockExtras(alone: alone, toggle: toggle);
  Widget callRow(
    Widget? extra, {
    List<ControlOptionEntry> menuExtras = const [],
  }) => CallControls(
    controller: controller,
    voice: voice,
    extraControl: extra,
    menuExtras: menuExtras,
    hints: hints,
  );
  bool fitsWith(int extraCount, {bool music = false}) => callRowFitsFor(
    context,
    ref,
    options,
    extraCount: extraCount,
    musicCaret: music,
  );
  // Nothing narrower than the bare row can fold away, so it spills over two lines instead.
  if (!fitsWith(0)) {
    return tightCallRows(
      ref,
      controller: controller,
      voice: voice,
      extra: extras,
      hints: hints,
    );
  }
  if (extras == null) return [callRow(null)];
  final fits = fitsWith(
    (alone ? 1 : 0) + (toggle != null ? toggleSlots : 0),
    music: alone,
  );
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

/// A call row too narrow for every control: what it leaves out gets a card row of its own above it, so leave stays beside the row it ends.
List<Widget> tightCallRows(
  WidgetRef ref, {
  required VoiceController controller,
  required VoiceFlags voice,
  Widget? extra,
  bool hints = true,
}) {
  final spills =
      extra != null ||
      canUseSoundboard(ref, voice.channelId) ||
      canUseCaptions(ref, voice.channelId) ||
      (voice.cameraEnabled && canSwitchCamera(ref, controller));
  return [
    if (spills)
      CallControls(
        controller: controller,
        voice: voice,
        extraControl: extra,
        spilledOnly: true,
        hints: false,
        ownsShortcuts: false,
      ),
    CallControls(
      controller: controller,
      voice: voice,
      tight: true,
      hints: hints,
    ),
  ];
}

/// [callRowFits] for the call in [options], reading which optional controls it draws.
bool callRowFitsFor(
  BuildContext context,
  WidgetRef ref,
  CallRowOptions options, {
  required int extraCount,
  bool musicCaret = false,
}) {
  final CallRowOptions(:width, :controller, :voice) = options;
  return callRowFits(
    context,
    width,
    switchCameraShown: voice.cameraEnabled && canSwitchCamera(ref, controller),
    soundboardShown: canUseSoundboard(ref, voice.channelId),
    captionsShown: canUseCaptions(ref, voice.channelId),
    shareCaret: voice.screenSharing && controller.video.screenShareNeedsSource,
    extraCount: extraCount,
    musicCaret: musicCaret,
  );
}

/// Whether the call row plus [extraCount] extra buttons fit one line at [width]
/// ([musicCaret]: the music button among them carries an options caret;
/// [shareCaret]: share draws its caret even at touch density, to switch source),
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
  bool soundboardShown = false,
  bool captionsShown = false,
  bool shareCaret = false,
  required int extraCount,
  bool musicCaret = false,
}) {
  final touch = AppTouchTargets.of(context);
  final hitTarget = touch ? AppSizes.rowTouch : AppSizes.rowPointer;
  final chip = AppSizes.controlMd > hitTarget ? AppSizes.controlMd : hitTarget;
  final button = chip + 2 * (focusRingGap + focusRingWidth);
  // mic, deafen, camera, [switch camera], share, [soundboard], [captions and mark], leave, and the extras.
  final controlCount =
      5 +
      (switchCameraShown ? 1 : 0) +
      (soundboardShown ? 1 : 0) +
      (captionsShown ? 2 : 0) +
      extraCount;
  const cardPadding = AppSpacing.s12 * 2 + 2;
  // The divider before leave takes the place of one gap: s4, 1dp, s4.
  const leaveDivider = 1.0;
  // Measured, not derived: each caret's width less what its primary half gives back, at pointer density only; the mic, camera and share each carry one.
  final carets = touch
      ? (shareCaret ? _touchShareCaret : 0.0)
      : (musicCaret ? 4 : 3) * AppSpacing.s24;
  final needed =
      carets +
      controlCount * button +
      (controlCount - 1) * AppSpacing.s8 +
      leaveDivider +
      cardPadding;
  return needed <= width;
}

/// Measured: the share caret's touch hit box plus the wider gap before share, less what the primary gives back.
const _touchShareCaret = AppSizes.rowTouch;
