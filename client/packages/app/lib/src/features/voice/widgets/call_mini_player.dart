// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call mini-player: a remote screen share or camera that keeps playing,
/// in a small draggable card, once you leave the channel the call is in.
///
/// It floats over the routed pane only, never the shell around it. On compact
/// widths that pane ends above the voice strip and the keyboard, so neither can
/// be covered by construction; the composer sits inside the pane, so the
/// bottom corners rest above [miniPlayerComposerReserve] instead. The card
/// renders `VoiceController.screenShareViewFor`/`cameraViewFor` - the same view
/// the call screen and fullscreen route show - so moving presentation is a
/// reparent and never a second subscription. It stays off a voice channel's own
/// page, whose centred "Switch to this call" it would cover. See docs/decisions/0040.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../composer/providers/composer_extent.dart';
import '../providers/call_mini_player.dart';
import '../../channels/providers/channel_by_id_provider.dart';
import '../providers/popout_window.dart';
import '../providers/share_watch.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../../../routing/breakpoints.dart';
import '../../../routing/routes.dart';
import '../screens/dm_call_pane.dart';
import 'focusable_video_press.dart';
import '../../channels/widgets/channel_rail.dart';
import '../../../providers/dock_reservation.dart';
import '../../../widgets/floating_clearance.dart';

/// Room kept clear at the bottom of the pane for a one-line composer and its
/// typing line; a draft that grows it is measured, see [composerExtentProvider].
const miniPlayerComposerReserve = 104.0;

/// Room kept clear under the channel header on widths where the header lives
/// inside the pane. Compact draws its app bar outside the pane.
const miniPlayerHeaderReserve = 60.0;

const _compactPlayerWidth = 192.0;
const _widePlayerWidth = 272.0;

typedef _Fit = ({Size player, MiniPlayerInsets insets, bool compact});

/// Whether the mini-player is on screen and where; exposed for tests.
const miniPlayerKey = Key('call_mini_player');

/// Wraps the routed [child] and floats the player over it while a call has a
/// feed to show and the user is somewhere other than the call.
class CallMiniPlayerHost extends ConsumerStatefulWidget {
  const CallMiniPlayerHost({
    super.key,
    required this.child,
    this.keyboardUp = false,
  });

  final Widget child;

  /// Read by the shell, above the scaffold: the scaffold strips the inset from
  /// the pane it hands down, so the host cannot see the keyboard itself.
  final bool keyboardUp;

  @override
  ConsumerState<CallMiniPlayerHost> createState() => _CallMiniPlayerHostState();
}

class _CallMiniPlayerHostState extends ConsumerState<CallMiniPlayerHost> {
  /// Set only while a finger holds the card; null means resting in a corner.
  Offset? _dragOrigin;

  late final StateController<double> _reach = ref.read(
    miniPlayerReachProvider.notifier,
  );

  @override
  void dispose() {
    final reach = _reach;
    Future.microtask(() {
      if (reach.mounted && reach.state != 0) reach.state = 0;
    });
    super.dispose();
  }

  /// Tells the window-level toasts how far up a card resting bottom-right reaches, once laid out.
  void _publishReach(Size region, _Fit? fit) {
    final corner = ref.read(miniPlayerCornerProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      var reach = 0.0;
      final box = context.findRenderObject();
      if (fit != null &&
          !fit.compact &&
          corner == MiniPlayerCorner.bottomRight &&
          box is RenderBox &&
          box.attached) {
        final top = cornerOrigin(corner, region, fit.player, fit.insets).dy;
        final global = box.localToGlobal(Offset(0, top)).dy;
        reach = math.max(0, MediaQuery.sizeOf(context).height - global);
      }
      if (_reach.state != reach) _reach.state = reach;
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = selectedChannelId(context);

    final (callState, callChannel) = ref.watch(
      voiceFlagsProvider.select((f) => (f.state, f.channelId)),
    );
    final feed = ref.watch(miniPlayerFeedProvider);
    // A voice channel page offers the call itself, centred, where a corner card would sit on its button.
    final onVoicePage =
        selected != null &&
        ref.watch(
              channelByIdProvider(selected).select((c) => c.valueOrNull?.kind),
            ) ==
            'voice';
    final dismissed = ref.watch(miniPlayerDismissedProvider);
    final visible =
        callState == VoiceSessionState.connected &&
        callChannel != null &&
        feed != null &&
        selected != callChannel &&
        !onVoicePage &&
        !dismissed &&
        !widget.keyboardUp;

    return LayoutBuilder(
      builder: (context, box) {
        final region = box.biggest;
        final fit = visible ? _fit(context, region) : null;
        _publishReach(region, fit);
        return Stack(
          fit: StackFit.expand,
          children: [
            FloatingClearance(
              bottom: fit == null ? 0 : _bottomClearance(fit),
              child: widget.child,
            ),
            if (fit != null) _positioned(region, fit, feed!, callChannel),
          ],
        );
      },
    );
  }

  /// How far a card resting in a bottom corner reaches above the composer.
  double _bottomClearance(_Fit fit) {
    final corner = ref.watch(miniPlayerCornerProvider);
    final bottom =
        corner == MiniPlayerCorner.bottomLeft ||
        corner == MiniPlayerCorner.bottomRight;
    if (!bottom) return 0;
    final above = fit.insets.bottom + fit.player.height;
    return math.max(0, above - ref.watch(composerExtentProvider));
  }

  /// The card's size and keep-out insets, or null where it does not fit.
  _Fit? _fit(BuildContext context, Size region) {
    final compact = LayoutClass.of(context) == LayoutClass.compact;
    // Compact has the call strip right below, so the card is only its video.
    final rowHeight = AppTouchTargets.of(context)
        ? AppSizes.rowTouch
        : AppSizes.rowPointer;
    final controlsHeight = compact ? 0.0 : rowHeight;
    final width = compact ? _compactPlayerWidth : _widePlayerWidth;
    final player = Size(width, width * 9 / 16 + controlsHeight);
    final composerExtent = ref.watch(composerExtentProvider);
    final insets = MiniPlayerInsets(
      top: compact ? 12 : miniPlayerHeaderReserve,
      bottom: math.max(
        miniPlayerComposerReserve,
        composerExtent + AppSpacing.s12,
      ),
    );
    if (region.width < player.width + 2 * insets.side ||
        region.height < player.height + insets.top + insets.bottom) {
      return null;
    }
    return (player: player, insets: insets, compact: compact);
  }

  Widget _positioned(
    Size region,
    _Fit fit,
    MiniPlayerFeed feed,
    String? callChannel,
  ) {
    final (:player, :insets, :compact) = fit;
    final corner = ref.watch(miniPlayerCornerProvider);
    final origin = _dragOrigin ?? cornerOrigin(corner, region, player, insets);
    return Stack(
      children: [
        AnimatedPositioned(
          duration: _dragOrigin != null
              ? Duration.zero
              : AppMotion.reduced(context, AppMotion.base),
          curve: AppMotion.entrance,
          left: origin.dx,
          top: origin.dy,
          width: player.width,
          height: player.height,
          child: GestureDetector(
            onPanStart: (_) => setState(() {
              _dragOrigin = cornerOrigin(corner, region, player, insets);
            }),
            onPanUpdate: (d) => setState(() {
              final next = (_dragOrigin ?? origin) + d.delta;
              _dragOrigin = Offset(
                next.dx.clamp(0, region.width - player.width),
                next.dy.clamp(0, region.height - player.height),
              );
            }),
            onPanEnd: (d) {
              final landed = nearestCorner(
                _dragOrigin ?? origin,
                d.velocity.pixelsPerSecond,
                region,
                player,
                insets,
              );
              moveMiniPlayer(ref, landed);
              setState(() => _dragOrigin = null);
            },
            // A grab cursor is the only sign on a pointer that the card moves.
            child: MouseRegion(
              cursor: _dragOrigin == null
                  ? SystemMouseCursors.grab
                  : SystemMouseCursors.grabbing,
              child: _MiniPlayerCard(
                feed: feed,
                compact: compact,
                onReturn: () => _returnToCall(callChannel),
                onHide: () =>
                    ref.read(miniPlayerDismissedProvider.notifier).state = true,
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _returnToCall(String? channelId) {
    if (channelId == null) return;
    // Same line as the voice strip's back button; see RailCallSummary.
    ref.read(dmCallOpenProvider.notifier).state = channelId;
    context.go(Routes.channel(channelId));
  }
}

class _MiniPlayerCard extends ConsumerWidget {
  const _MiniPlayerCard({
    required this.feed,
    required this.compact,
    required this.onReturn,
    required this.onHide,
  });

  final MiniPlayerFeed feed;

  /// The compact call strip already carries mute and leave, so the card drops them.
  final bool compact;
  final VoidCallback onReturn;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final controller = ref.read(voiceControllerProvider.notifier);
    final micOn = ref.watch(
      voiceFlagsProvider.select((f) => f.microphoneEnabled),
    );
    final view = switch (feed.kind) {
      FeedKind.screenShare => controller.screenShareViewFor(feed.identity),
      FeedKind.camera => controller.cameraViewFor(feed.identity),
    };
    final hide = AppIconButton(
      icon: AppIcons.dismiss,
      semanticLabel: 'Hide the mini-player',
      tooltip: 'Hide the mini-player',
      onPressed: onHide,
    );
    final stop = feed.kind == FeedKind.screenShare
        ? AppIconButton(
            icon: AppIcons.tileHide,
            semanticLabel: 'Stop watching',
            tooltip: 'Stop watching',
            onPressed: () =>
                ref.read(shareWatchProvider.notifier).stop(feed.identity),
          )
        : null;
    final label = switch (feed.kind) {
      FeedKind.screenShare => "${feed.name}'s screen",
      FeedKind.camera => feed.name,
    };

    return DecoratedBox(
      key: miniPlayerKey,
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: tokens.borderSubtle),
        boxShadow: AppShadows.canvasTile,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.card - 1),
        child: Column(
          children: [
            Expanded(
              child: FocusableVideoPress(
                semanticLabel: 'Return to the call',
                onPressed: onReturn,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: Colors.black,
                      child: IgnorePointer(child: view),
                    ),
                    const _LabelScrim(),
                    if (compact)
                      Positioned(
                        top: 0,
                        right: 0,
                        // The video is any colour, so the buttons carry their own dark backing in either theme.
                        child: Theme(
                          data: forcedDarkTheme,
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              color: Color(0x8C000000),
                              borderRadius: BorderRadius.only(
                                bottomLeft: Radius.circular(AppRadii.card),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [?stop, hide],
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      left: AppSpacing.s8,
                      right: AppSpacing.s8,
                      bottom: AppSpacing.s4,
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.micro.copyWith(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!compact)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  AppIconButton(
                    icon: micOn ? AppIcons.mic : AppIcons.micOff,
                    semanticLabel: micOn ? 'Mute' : 'Unmute',
                    tooltip: micOn ? 'Mute' : 'Unmute',
                    onPressed: controller.toggleMicrophone,
                  ),
                  AppIconButton(
                    icon: AppIcons.leaveCall,
                    semanticLabel: 'Leave call',
                    tooltip: 'Leave call',
                    variant: AppIconButtonVariant.danger,
                    onPressed: controller.leave,
                  ),
                  if (ref.watch(popOutSupportedProvider))
                    AppIconButton(
                      icon: AppIcons.popOut,
                      semanticLabel: 'Pop out',
                      tooltip: 'Pop out',
                      onPressed: () =>
                          ref.read(popOutFeedsProvider.notifier).open(feed),
                    ),
                  ?stop,
                  hide,
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Keeps the white name line legible over a bright picture.
class _LabelScrim extends StatelessWidget {
  const _LabelScrim();

  @override
  Widget build(BuildContext context) => const Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    height: 28,
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x00000000), Color(0xB3000000)],
          ),
        ),
      ),
    ),
  );
}
