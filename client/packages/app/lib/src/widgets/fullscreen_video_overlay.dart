// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A participant's camera or a shared screen, filled to the whole window.
///
/// One overlay serves both kinds rather than a second implementation for
/// each: the live view is the exact same `Widget` `CallParticipantTile` and
/// `ScreenShareStage` already render, from
/// `VoiceController.cameraViewFor`/`screenShareViewFor`, so nothing here ever
/// touches a LiveKit type or a subscription - entering or leaving full screen
/// is a UI change, never a track change.
///
/// Modelled on `fullscreen_image_viewer.dart`'s own shape (a root-navigator
/// route, a dark `Theme` so `Text`/`Icon` do not fall back to their debug
/// style, `AppMotion`-reduced transitions) rather than a second one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/phone_landscape.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';

/// Which live view a tile was showing when it was expanded.
enum FullscreenVideoKind { camera, screenShare }

/// Opens [identity]'s feed full screen. [label] is the name line shown above
/// it - already resolved by the caller ("Your camera", "Ada's screen"), since
/// only the caller knows whether the subject is the local participant.
Future<void> showFullscreenVideo(
  BuildContext context, {
  required String identity,
  required String label,
  required FullscreenVideoKind kind,
}) {
  final duration = AppMotion.reduced(context, AppMotion.base);
  return Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      pageBuilder: (_, animation, _) => FadeTransition(
        opacity: animation,
        child: FullscreenVideoView(
          identity: identity,
          label: label,
          kind: kind,
        ),
      ),
    ),
  );
}

/// The full-bleed stage itself: black behind the video like every other call
/// surface, a name line, and a close control - Escape, the close button and
/// the platform back gesture all reach the same pop, since this is an
/// ordinary route rather than a barrier that swallows any of them.
class FullscreenVideoView extends ConsumerStatefulWidget {
  const FullscreenVideoView({
    super.key,
    required this.identity,
    required this.label,
    required this.kind,
  });

  final String identity;
  final String label;
  final FullscreenVideoKind kind;

  @override
  ConsumerState<FullscreenVideoView> createState() =>
      _FullscreenVideoViewState();
}

class _FullscreenVideoViewState extends ConsumerState<FullscreenVideoView>
    with WidgetsBindingObserver {
  /// Set the instant a pop is scheduled, so a participant leaving *and* their
  /// camera flag flipping in the same frame cannot schedule the pop twice.
  bool _exiting = false;

  /// Whether the name line and close control show over a landscape video; a
  /// tap on the video toggles them so nothing covers the picture.
  bool _controlsShown = true;

  late final OrientationChannel _orientation;

  @override
  void initState() {
    super.initState();
    _orientation = ref.read(orientationChannelProvider);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_allowLandscape());
  }

  /// The ambient size is kept portrait for the routed app, so it never changes
  /// on rotation; this route has to hear the window itself.
  @override
  void didChangeMetrics() {
    if (mounted) setState(() {});
  }

  /// A locked phone may rotate only while this route is up (decision 0058);
  /// anywhere else nothing answers and nothing changes.
  Future<void> _allowLandscape() async {
    final lockedPhone = await _orientation.allowLandscape(true);
    if (!lockedPhone || !mounted) return;
    ref.read(portraitLockedPhoneProvider.notifier).state = true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_orientation.allowLandscape(false));
    super.dispose();
  }

  /// Whether the feed this route opened for is still actually live. A
  /// participant leaving the call, or turning off the very camera (or share)
  /// this route is showing, must close it behind them - the alternative is a
  /// frozen or blank stage with no way to know it stopped being the truth.
  bool _stillLive(List<VoiceParticipant> participants) {
    final participant = participants
        .where((p) => p.identity == widget.identity)
        .firstOrNull;
    if (participant == null) return false;
    return switch (widget.kind) {
      FullscreenVideoKind.camera => participant.isCameraOn,
      FullscreenVideoKind.screenShare => participant.isScreenSharing,
    };
  }

  void _exit() {
    if (_exiting) return;
    _exiting = true;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final participants = ref.watch(voiceParticipantsProvider);
    final controller = ref.read(voiceControllerProvider.notifier);
    final live = _stillLive(participants);
    // Scheduled: a build method must not itself change the navigator stack.
    if (!live && !_exiting) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _exit());
    }

    final lockedPhone = ref.watch(portraitLockedPhoneProvider);
    // The routed app sees a locked phone's window kept portrait; this route alone reads the real one.
    final real = MediaQueryData.fromView(View.of(context));
    final landscape = lockedPhone && real.size.width > real.size.height;
    final video = live
        ? (widget.kind == FullscreenVideoKind.camera
              ? controller.cameraViewFor(widget.identity)
              : controller.screenShareViewFor(widget.identity))
        : const SizedBox.shrink();
    final header = _VideoHeader(label: widget.label, onClose: _exit);
    final Widget stage = landscape
        ? GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _controlsShown = !_controlsShown),
            child: Stack(
              children: [
                Positioned.fill(child: video),
                if (_controlsShown)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SafeArea(bottom: false, child: header),
                  ),
              ],
            ),
          )
        : SafeArea(
            child: Column(
              children: [
                header,
                Expanded(child: video),
              ],
            ),
          );

    final Widget page = CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _exit},
      child: Focus(
        autofocus: true,
        child: Theme(
          data: buildTheme(Brightness.dark, AppTokens.dark),
          child: Material(
            type: MaterialType.transparency,
            child: ColoredBox(color: Colors.black, child: stage),
          ),
        ),
      ),
    );
    if (!lockedPhone) return page;
    return MediaQuery(
      data: real.copyWith(
        textScaler: MediaQuery.textScalerOf(context),
        disableAnimations: MediaQuery.disableAnimationsOf(context),
      ),
      child: page,
    );
  }
}

class _VideoHeader extends StatelessWidget {
  const _VideoHeader({required this.label, required this.onClose});

  final String label;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s8,
        vertical: AppSpacing.s4,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.ui.copyWith(color: tokens.textSecondary),
            ),
          ),
          AppIconButton(
            icon: AppIcons.dismiss,
            semanticLabel: 'Exit full screen',
            size: AppIconButtonSize.touch,
            touch: true,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// The corner control a tile offers to open its live view full screen.
///
/// A sibling in the caller's own `Stack`, never nested inside a tile's
/// `ExcludeSemantics` - the same shape `RailDragHandle`'s own fix established
/// for exactly this trap: a `GestureDetector` excluded from semantics, with
/// an explicit outer [Semantics] as the sole source of the button's
/// accessible name, so it does not inherit or bleed into the tile's own.
class ExpandVideoButton extends StatelessWidget {
  const ExpandVideoButton({
    super.key,
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    onTap: onTap,
    child: GestureDetector(
      excludeFromSemantics: true,
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          shape: BoxShape.circle,
        ),
        child: const Icon(AppIcons.expand, size: 14, color: Colors.white),
      ),
    ),
  );
}
