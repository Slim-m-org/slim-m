// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How a dock's call row carries the controls that are not part of every call:
/// soundboard, transcript, the music button while alone, and the canvas toggle.
///
/// They draw in the More menu unless the person pinned them to the dock. The
/// row never shrinks a control: when pinned ones do not fit they go back to
/// More, and when even the primary row plus More does not fit, the carets go.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../audio/hold_music_player.dart' show holdMusicAvailableProvider;
import '../providers/call_solo.dart';
import '../providers/camera_switch.dart';
import '../providers/hold_music_actions.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../providers/voice_settings_controller.dart';
import '../../../widgets/floating_dock_card.dart' show dockCardSidePadding;
import '../widgets/dock_item.dart';
import '../widgets/dock_items.dart';
import '../widgets/voice_call_controls.dart';
import 'hold_music_dock_toggle.dart';

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
  return chip + 2 * (focusRingGap + focusRingWidth) + dockButtonGap(context);
}

/// The music button's width: a [dockButtonExtent] and its options caret at pointer density.
double dockExtraExtent(BuildContext context) {
  final caret = AppTouchTargets.of(context) ? 0.0 : AppSpacing.s24;
  return dockButtonExtent(context) + caret;
}

/// The music item while alone, then [toggle]: what a dock adds beside the call's own controls.
List<DockItem> dockExtras(
  WidgetRef ref, {
  required bool alone,
  DockItem? toggle,
}) => [
  if (alone)
    DockItem(
      id: 'music',
      name: 'Music',
      inline: const HoldMusicDockToggle(),
      entries: holdMusicMenuOptions(ref),
    ),
  ?toggle,
];

/// What [callRowsWithExtras] lays out beside the call row.
class CallRowOptions {
  const CallRowOptions({
    required this.width,
    required this.controller,
    required this.voice,
    this.toggle,
    this.hints = true,
  });

  final double width;
  final VoiceController controller;
  final VoiceFlags voice;

  /// The canvas toggle, or the bots' controls: one more optional item.
  final DockItem? toggle;

  /// See [CallControls.hints].
  final bool hints;
}

/// The card rows for a call: one call row, with the optional controls inline
/// when they are pinned and [CallRowOptions.width] holds them, in More when
/// not, and without carets when even that does not fit.
List<Widget> callRowsWithExtras(
  BuildContext context,
  WidgetRef ref,
  CallRowOptions options,
) {
  final extras = dockExtras(
    ref,
    alone: soloMusicInDock(context, ref),
    toggle: options.toggle,
  );
  final fit = callRowFitFor(context, ref, options, extras: extras);
  final pinRoom = callRowPinRoom(context, ref, options, extras: extras);
  final hasMore =
      fit == DockFit.tight &&
      splitDockItems(
        _itemsFor(context, ref, options, extras),
        pinned: const [],
        inlineAllowed: false,
      ).hasMore;
  return [
    if (hasMore)
      CallControls(
        controller: options.controller,
        voice: options.voice,
        extras: extras,
        inlineExtras: false,
        spilledOnly: true,
        pinRoom: pinRoom,
        hints: false,
        ownsShortcuts: false,
      ),
    CallControls(
      controller: options.controller,
      voice: options.voice,
      extras: extras,
      inlineExtras: fit != DockFit.moreOnly,
      pinRoom: pinRoom,
      tight: fit == DockFit.tight,
      hints: options.hints,
    ),
  ];
}

/// How much of a call row fits.
enum DockFit { pinned, moreOnly, tight }

/// Whether the row holds [split]'s inline items at [options]'s width.
bool _rowFits(BuildContext context, CallRowOptions options, DockSplit split) {
  final CallRowOptions(:width, :controller, :voice) = options;
  final shareCaret =
      voice.screenSharing && controller.video.screenShareNeedsSource;
  return callRowFits(
    context,
    width,
    optionalCount: split.buttonCount,
    shareCaret: shareCaret,
    musicCaret: split.inline.any((i) => i.id == 'music'),
  );
}

/// The widest form of the row for [options] that fits: pinned items inline, only More, or More in a row above with no carets.
DockFit callRowFitFor(
  BuildContext context,
  WidgetRef ref,
  CallRowOptions options, {
  required List<DockItem> extras,
}) {
  final items = _itemsFor(context, ref, options, extras);
  final pinned = ref.watch(
    voiceSettingsControllerProvider.select((s) => s.dockPinned),
  );
  if (_rowFits(
    context,
    options,
    splitDockItems(items, pinned: pinned, inlineAllowed: true),
  )) {
    return DockFit.pinned;
  }
  if (_rowFits(
    context,
    options,
    splitDockItems(items, pinned: pinned, inlineAllowed: false),
  )) {
    return DockFit.moreOnly;
  }
  return DockFit.tight;
}

/// Whether every control still in More would land inline if pinned, by the same fit [callRowFitFor] applies.
bool callRowPinRoom(
  BuildContext context,
  WidgetRef ref,
  CallRowOptions options, {
  required List<DockItem> extras,
}) {
  final items = _itemsFor(context, ref, options, extras);
  final pinned = ref.watch(
    voiceSettingsControllerProvider.select((s) => s.dockPinned),
  );
  return [
    for (final item in items)
      if (!item.keepInline && !pinned.contains(item.id)) item,
  ].every(
    (candidate) => _rowFits(
      context,
      options,
      splitDockItems(
        items,
        pinned: [...pinned, candidate.id],
        inlineAllowed: true,
      ),
    ),
  );
}

List<DockItem> _itemsFor(
  BuildContext context,
  WidgetRef ref,
  CallRowOptions options,
  List<DockItem> extras,
) => buildDockItems(
  context,
  ref,
  voice: options.voice,
  extras: extras,
  canSwitch:
      options.voice.cameraEnabled && canSwitchCamera(ref, options.controller),
  switchCameraButton: const SizedBox.shrink(),
  switchCamera: () {},
);

/// How many optional buttons (More included) the pinned form of [options] draws, and whether the music one carries a caret.
({int count, bool musicCaret}) dockInlineCount(
  BuildContext context,
  WidgetRef ref,
  CallRowOptions options,
) {
  final extras = dockExtras(
    ref,
    alone: soloMusicInDock(context, ref),
    toggle: options.toggle,
  );
  final split = splitDockItems(
    _itemsFor(context, ref, options, extras),
    pinned: ref.watch(
      voiceSettingsControllerProvider.select((s) => s.dockPinned),
    ),
    inlineAllowed: true,
  );
  return (
    count: split.buttonCount,
    musicCaret: split.inline.any((i) => i.id == 'music'),
  );
}

/// Whether the call row plus [optionalCount] optional buttons fit one line at [width]
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
  required int optionalCount,
  bool shareCaret = false,
  bool musicCaret = false,
}) {
  final touch = AppTouchTargets.of(context);
  final hitTarget = touch ? AppSizes.rowTouch : AppSizes.rowPointer;
  final chip = AppSizes.controlMd > hitTarget ? AppSizes.controlMd : hitTarget;
  final button = chip + 2 * (focusRingGap + focusRingWidth);
  // mic, deafen, camera, share and leave, then the optional buttons (More included).
  final controlCount = 5 + optionalCount;
  final cardPadding = dockCardSidePadding(context) * 2 + 2;
  // The divider before leave takes the place of one gap: s4, 1dp, s4.
  const leaveDivider = AppSpacing.s4 * 2 + 1;
  // Measured, not derived: each caret's width less what its primary half gives back, at pointer density only; the mic, camera and share each carry one.
  final carets = touch
      ? (shareCaret ? _touchShareCaret : 0.0)
      : (musicCaret ? 4 : 3) * AppSpacing.s24;
  final needed =
      carets +
      controlCount * button +
      (controlCount - 2) * dockButtonGap(context) +
      leaveDivider +
      cardPadding;
  return needed <= width;
}

/// Measured: the share caret's touch hit box plus the wider gap before share, less what the primary gives back.
const _touchShareCaret = AppSizes.rowTouch;
