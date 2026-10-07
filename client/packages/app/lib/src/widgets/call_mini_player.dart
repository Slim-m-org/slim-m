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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/call_mini_player.dart';
import '../providers/channel_by_id_provider.dart';
import '../providers/popout_window.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../routing/breakpoints.dart';
import '../routing/routes.dart';
import '../screens/dm_call_pane.dart';
import 'channel_rail.dart';

/// Room kept clear at the bottom of the pane for the composer and its typing
/// line; the player's bottom corners rest above it.
const miniPlayerComposerReserve = 104.0;

/// Room kept clear under the channel header on widths where the header lives
/// inside the pane. Compact draws its app bar outside the pane.
const miniPlayerHeaderReserve = 60.0;

const _compactPlayerWidth = 192.0;
const _widePlayerWidth = 272.0;

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
  /// The channel the user was on when they hid the player; the next channel
  /// change clears it, so "hide" means "until I go somewhere else".
  bool _hidden = false;
  String? _hiddenOn;

  /// Set only while a finger holds the card; null means resting in a corner.
  Offset? _dragOrigin;

  @override
  Widget build(BuildContext context) {
    final selected = selectedChannelId(context);
    if (_hidden && selected != _hiddenOn) _hidden = false;

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
    final visible =
        callState == VoiceSessionState.connected &&
        feed != null &&
        selected != callChannel &&
        !onVoicePage &&
        !_hidden &&
        !widget.keyboardUp;

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (visible)
          LayoutBuilder(
            builder: (context, box) =>
                _positioned(context, box.biggest, feed, callChannel),
          ),
      ],
    );
  }

  Widget _positioned(
    BuildContext context,
    Size region,
    MiniPlayerFeed feed,
    String? callChannel,
  ) {
    final compact = LayoutClass.of(context) == LayoutClass.compact;
    // Compact has the call strip right below, so the card is only its video.
    final controlsHeight = compact
        ? 0.0
        : AppTouchTargets.of(context)
        ? AppSizes.rowTouch
        : AppSizes.rowPointer;
    final width = compact ? _compactPlayerWidth : _widePlayerWidth;
    final player = Size(width, width * 9 / 16 + controlsHeight);
    final insets = MiniPlayerInsets(
      top: compact ? 12 : miniPlayerHeaderReserve,
      bottom: miniPlayerComposerReserve,
    );
    if (region.width < player.width + 2 * insets.side ||
        region.height < player.height + insets.top + insets.bottom) {
      return const SizedBox.shrink();
    }

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
              ref.read(miniPlayerCornerProvider.notifier).state = landed;
              setState(() => _dragOrigin = null);
            },
            child: _MiniPlayerCard(
              feed: feed,
              compact: compact,
              onReturn: () => _returnToCall(callChannel),
              onHide: () => setState(() {
                _hidden = true;
                _hiddenOn = selectedChannelId(context);
              }),
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
              child: Semantics(
                button: true,
                label: 'Return to the call',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onReturn,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: Colors.black,
                        child: IgnorePointer(child: view),
                      ),
                      if (compact) Positioned(top: 0, right: 0, child: hide),
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
                          ref.read(popOutFeedProvider.notifier).state = feed,
                    ),
                  hide,
                ],
              ),
          ],
        ),
      ),
    );
  }
}
