// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A "Volume..." row's own destination, reached from a quick-actions menu on
/// a call tile or a canvas bubble (`participant_call_menu.dart`) - a
/// standalone anchored popover holding just [ParticipantVolumeControl],
/// never a bare slider dropped directly into the menu itself. A `Slider`'s
/// own drag gesture fights a menu's outside-tap-to-dismiss model (a drag
/// starting on the thumb reads as a tap landing outside the row it is on),
/// which is exactly the "submenu or a popover row" the design calls for
/// instead.
///
/// Positioned the same way `member_profile.dart`'s own popover is - an
/// anchored popover on a pointer layout, a bottom sheet on a compact one -
/// reusing [AnchoredMemberPopover] itself (`member_profile_popover.dart`)
/// rather than rewriting its placement math. Only the dialog/sheet-launching
/// glue around it is this file's own small copy of `showMemberProfile`'s,
/// since that glue is not factored into a reusable function there.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/voice_controller.dart';
import '../../members/widgets/member_profile_popover.dart';
import 'participant_audio_controls.dart'
    show ParticipantScreenAudioSection, ParticipantVolumeControl;

const double _popoverWidth = 260;

/// Opens the volume popover for [identity], anchored to [anchor]; with
/// [screenOnly], just their shared screen's sound, as a share's own control.
Future<void> showParticipantVolumePopover(
  BuildContext anchor, {
  required String identity,
  required String name,
  required VoiceController controller,
  bool screenOnly = false,
}) {
  final compact = MediaQuery.sizeOf(anchor).width < kCompactWidth;
  final content = _ParticipantVolumePopoverBody(
    name: name,
    identity: identity,
    controller: controller,
    screenOnly: screenOnly,
  );

  // A sheet is already a surface, so on a phone the controls sit straight in it (desktop-vs-mobile.md rule 3).
  if (compact) {
    return showAppSheet<void>(
      anchor,
      builder: (context) => _ParticipantVolumeSheetBody(
        name: name,
        identity: identity,
        controller: controller,
        screenOnly: screenOnly,
      ),
    );
  }

  final box = anchor.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(anchor).context.findRenderObject() as RenderBox?;
  final origin = box == null || overlay == null
      ? Offset.zero
      : box.localToGlobal(Offset.zero, ancestor: overlay);
  final anchorSize = box?.size ?? Size.zero;

  return showGeneralDialog<void>(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.transparent,
    transitionDuration: AppMotion.reduced(anchor, AppMotion.base),
    pageBuilder: (context, _, __) => AnchoredMemberPopover(
      origin: origin,
      anchorSize: anchorSize,
      child: content,
    ),
    transitionBuilder: (context, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

String _title(String name, {required bool screenOnly}) =>
    screenOnly ? "$name's screen audio" : 'Volume for $name';

List<Widget> _controls(
  String identity,
  VoiceController controller, {
  required bool screenOnly,
}) => [
  if (!screenOnly)
    ParticipantVolumeControl(
      identity: identity,
      controller: controller,
      showLabel: false,
    ),
  if (controller.hasScreenAudio(identity)) ...[
    if (!screenOnly) const SizedBox(height: AppSpacing.s8),
    ParticipantScreenAudioSection(
      identity: identity,
      controller: controller,
      showLabel: !screenOnly,
    ),
  ],
];

class _ParticipantVolumePopoverBody extends StatelessWidget {
  const _ParticipantVolumePopoverBody({
    required this.name,
    required this.identity,
    required this.controller,
    required this.screenOnly,
  });

  final String name;
  final String identity;
  final VoiceController controller;
  final bool screenOnly;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      width: _popoverWidth,
      padding: const EdgeInsets.all(AppSpacing.s12),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: tokens.borderSubtle),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _title(name, screenOnly: screenOnly),
            style: AppText.ui.copyWith(color: tokens.textPrimary),
          ),
          const SizedBox(height: AppSpacing.s8),
          ..._controls(identity, controller, screenOnly: screenOnly),
        ],
      ),
    );
  }
}

/// The phone sheet's body: one title over the control, no card of its own.
class _ParticipantVolumeSheetBody extends StatelessWidget {
  const _ParticipantVolumeSheetBody({
    required this.name,
    required this.identity,
    required this.controller,
    required this.screenOnly,
  });

  final String name;
  final String identity;
  final VoiceController controller;
  final bool screenOnly;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s16,
          AppSpacing.s4,
          AppSpacing.s16,
          AppSpacing.s16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _title(name, screenOnly: screenOnly),
              style: AppText.ui.copyWith(color: tokens.textPrimary),
            ),
            const SizedBox(height: AppSpacing.s8),
            ..._controls(identity, controller, screenOnly: screenOnly),
          ],
        ),
      ),
    );
  }
}
