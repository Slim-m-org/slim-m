// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail's fixed top and bottom bars: the Space header (with its menu)
/// and the signed-in user's footer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../desktop/update_watch.dart';
import '../providers/presence_view.dart';
import '../providers/providers.dart';
import '../providers/status_text.dart';
import '../providers/sync_controller.dart';
import '../providers/sync_failure.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../routing/breakpoints.dart';
import '../routing/routes.dart';
import 'presence_menu.dart';
import 'rail_call_summary.dart';
import 'space_menu_button.dart';

/// Whether this rail has content beside it, so its own right edge is never
/// the physical screen edge: true at every width the app shows it beside a
/// conversation, false for the one compact case where it fills the screen.
bool _railHasNeighbour(BuildContext context) =>
    LayoutClass.of(context).showsBothPanes;

/// The server's own identity, for the header's name line. Real endpoint;
/// there is no separate per-deployment "workspace name" concept, so this is
/// `/version`'s `name`.
final serverInfoProvider = FutureProvider.autoDispose<api.Version>(
  (ref) => ref.watch(apiProvider).version(),
);

/// No subtitle any more: it used to carry the member count and this build's
/// version, both dropped (design review note 22/7). A version is not a
/// property of the Space, and duplicated the desktop title bar's own copy;
/// `AppInfoSection` (Personal settings > App) is the one place every
/// platform reads it now. The member count is the member pane's own count
/// (`MEMBERS · N`), one line below where a caller already looks for it,
/// rather than a second tally here nobody asked to compare.
///
/// This header renders on every platform, the desktop title bar included
/// (0012's 2026-09-25 addendum): the title bar keeps the Space name and the
/// build version as the window's own title, while this header carries the
/// Space's identity, its connection dot and its menu.
///
/// The name line also carries [SpaceConnectionDot] now (owner request,
/// 2026-08-03): the Space's own connection used to show only in the profile
/// footer below, by way of [RailUserFooter] overriding the person's own
/// presence with the socket's state - which conflated "is this device
/// connected" with "what did I set my status to" in the one place a person's
/// own identity lives. It is a dedicated indicator beside the Space's name
/// instead, the same place a member list gives a person their own status.
class RailHeader extends ConsumerWidget {
  const RailHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final server = ref.watch(serverInfoProvider);
    // Latched past the first failure, so a retry loop does not flip this dot.
    final syncStatus = displaySyncStatus(
      ref.watch(syncControllerProvider),
      ref.watch(hasFailedSinceLiveProvider),
    );
    // The decoration bleeds to the screen edge while [SafeArea] insets only
    // the content, so the rail's own colour fills the status-bar strip.
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
      ),
      child: SafeArea(
        bottom: false,
        // Right is only the physical edge when nothing sits beside the rail.
        right: !_railHasNeighbour(context),
        // minHeight, not height: the name line grows under a larger OS text scale.
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSizes.headerBar),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      SpaceConnectionDot(
                        status: syncStatus,
                        failure: ref.watch(syncFailureProvider),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          server.valueOrNull?.name ?? 'slim-m',
                          overflow: TextOverflow.ellipsis,
                          style: AppText.body.copyWith(
                            color: tokens.textPrimary,
                            fontWeight: AppWeights.semi,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SpaceMenuButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The Space's connection to the server, shown beside its name in
/// [RailHeader]. Built directly on [AppStatusDotPainter] rather than
/// [AppStatusDot]: that widget's own accessible label always names a
/// person's presence ("Online", "Away"), which is the wrong claim to make
/// about a link to a server, so this carries its own label instead.
///
/// The three shapes mirror [AppStatusDot.shapeOf]'s own vocabulary
/// (`filledDisc`/`triangle`/`hollowRing`) for the same reason that one
/// exists: a screenshot in a bug report, or a colour-blind viewer, still has
/// to be able to tell live from offline with the colour removed.
///
/// The colour choice mirrors the retired `RailConnectionBar`'s own: offline
/// is the one state that has actually stopped, so it alone carries the warn
/// tone, while connecting is transient and stays neutral.
class SpaceConnectionDot extends StatelessWidget {
  const SpaceConnectionDot({super.key, required this.status, this.failure});

  final SyncStatus status;

  /// Why sync is down, when something knows: a refused session and an
  /// unreachable server look identical here and recover differently.
  final SyncFailure? failure;

  static const Map<SyncStatus, AppStatusShape> _shapeOf = {
    SyncStatus.live: AppStatusShape.filledDisc,
    SyncStatus.connecting: AppStatusShape.triangle,
    SyncStatus.offline: AppStatusShape.hollowRing,
  };

  static const double _size = 8;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final color = switch (status) {
      SyncStatus.live => tokens.status.online,
      SyncStatus.connecting => tokens.textSecondary,
      SyncStatus.offline => tokens.warnText,
    };
    final label = connectionLabel(status, failure);
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        // A connection flip cross-fades on [AppStatusDot]'s own clock rather
        // than repainting in one frame; the key scopes the swap to the state.
        child: AnimatedSwitcher(
          duration: AppMotion.reduced(context, AppMotion.fast),
          child: CustomPaint(
            key: ValueKey(status),
            size: const Size.square(_size),
            painter: AppStatusDotPainter(
              shape: _shapeOf[status]!,
              color: color,
              backgroundColor: tokens.surfaceSunken,
            ),
          ),
        ),
      ),
    );
  }
}

/// Says plainly whether messages are arriving, under the compact app bar
/// where there is no Space name for [SpaceConnectionDot] to sit beside
/// (`home_shell.dart`'s narrow layout swaps the whole rail for a channel app
/// bar). The wide rail no longer mounts this: see [RailHeader]'s own doc.
class RailConnectionBar extends ConsumerWidget {
  const RailConnectionBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Latched past the first failure, so a retry loop does not flip this bar.
    final status = displaySyncStatus(
      ref.watch(syncControllerProvider),
      ref.watch(hasFailedSinceLiveProvider),
    );
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // Offline (messages have stopped) carries the warn tone; connecting is transient and stays neutral.
    final (label, icon, color) = switch (status) {
      SyncStatus.connecting => (
        'Connecting',
        AppIcons.pending,
        tokens.textSecondary,
      ),
      SyncStatus.offline => (
        // Drops "retrying" for a refusal: it does keep trying, and saying so would invite a wait for something that cannot arrive.
        connectionLabel(status, ref.watch(syncFailureProvider)),
        AppIcons.retry,
        tokens.warnText,
      ),
      SyncStatus.live => ('', AppIcons.info, tokens.textSecondary),
    };

    // One AnimatedSize across both states: the banner pushes content by its
    // height (motion spec 08), growing and shrinking over the panel duration
    // instead of jumping the rail's footer around.
    return AnimatedSize(
      duration: AppMotion.reducedSize(context, AppMotion.base),
      curve: AppMotion.entrance,
      alignment: Alignment.topCenter,
      child: status == SyncStatus.live
          ? const SizedBox(width: double.infinity)
          : Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s16,
                vertical: AppSpacing.s8,
              ),
              decoration: BoxDecoration(
                color: status == SyncStatus.offline ? tokens.warnSoft : null,
                border: Border(top: BorderSide(color: tokens.borderSubtle)),
              ),
              child: Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    Icon(icon, size: AppSizes.icon16, color: color),
                    const SizedBox(width: AppSpacing.s8),
                    Expanded(
                      child: Text(
                        label,
                        style: AppText.caption.copyWith(color: color),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// The mic/deafen toggle pair in [RailUserFooter]'s row.
///
/// Takes [VoiceFlags] rather than the full [VoiceState] on purpose: the
/// footer has no use for the roster, and typing this as the narrower flags
/// object makes it impossible for a future caller to thread it back in.
List<Widget> railVoiceToggleButtons({
  required VoiceFlags voice,
  required VoiceController voiceController,
}) {
  final inCall = voice.state == VoiceSessionState.connected;
  return [
    AppIconButton(
      icon: voice.microphoneEnabled ? AppIcons.mic : AppIcons.micOff,
      semanticLabel: voice.microphoneEnabled ? 'Mute' : 'Unmute',
      tooltip: inCall ? null : 'Not in a call',
      onPressed: inCall ? voiceController.toggleMicrophone : null,
    ),
    // Same icon either way, the toggle carried by `active`: there is no
    // dedicated "deafened" glyph in AppIcons.
    AppIconButton(
      icon: AppIcons.headphones,
      semanticLabel: voice.deafened ? 'Undeafen' : 'Deafen',
      active: voice.deafened,
      tooltip: inCall ? null : 'Not in a call',
      onPressed: inCall ? voiceController.toggleDeafen : null,
    ),
  ];
}

/// The personal-settings nav button beside [railVoiceToggleButtons].
///
/// Carries a dot when an update is waiting. The banner says the same thing in
/// words, but it is dismissible and this is not: once the banner is gone the
/// only remaining sign used to be relaunching and hitting the splash check
/// again. The dot points at the pane that can act on it, and About is where
/// the two version numbers and the manual re-check live.
Widget railSettingsButton(BuildContext context) => Consumer(
  builder: (context, ref, _) {
    final pending = ref.watch(updatePendingProvider);
    final button = AppIconButton(
      icon: AppIcons.settings,
      semanticLabel: pending
          ? 'Personal settings, an update is available'
          : 'Personal settings',
      onPressed: () => context.push(Routes.personalSettings),
    );
    if (!pending) return button;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        button,
        // The dot means "something is waiting" by being there, not by its hue.
        Positioned(
          top: 2,
          right: 2,
          child: ExcludeSemantics(child: _UpdateDot(key: updateBadgeDotKey)),
        ),
      ],
    );
  },
);

/// Finds the gear's dot in a test, which nothing else about the rail can be
/// mistaken for.
const updateBadgeDotKey = Key('rail-gear-update-dot');

/// The gear's pending-update dot. Sized against nothing in particular: it has
/// to read as a mark on the icon rather than as a second control, and 8 is the
/// smallest that survives a HiDPI downscale without turning into a smudge.
class _UpdateDot extends StatelessWidget {
  const _UpdateDot({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: tokens.accent,
        shape: BoxShape.circle,
        // A ring of the surface behind it, so the dot stays legible on the glyph.
        border: Border.all(color: tokens.surfaceSunken, width: 1.5),
      ),
    );
  }
}

/// Below this footer width the name line gives way to the controls: avatar,
/// three buttons and their insets leave too little for a readable name.
const double _footerNameMinWidth = 200;

class RailUserFooter extends ConsumerWidget {
  const RailUserFooter({super.key, this.activeChannelId});

  /// The channel currently shown beside or instead of this rail. A call
  /// already live in that channel has its own full call UI, so the footer's
  /// call-elsewhere row (name, duration, leave) is gated on this; mic and
  /// deafen are not, since they control whichever call is live regardless of
  /// which channel is on screen.
  ///
  /// This row's status line is the person's own presence word from
  /// [presenceForProvider], whatever the socket is doing: the Space's
  /// connection is [SpaceConnectionDot]'s job in [RailHeader], not this one's.
  ///
  /// A typed status (`api.Me.statusText`) joins the presence word once one is
  /// set ("online · swagging"), the same pair the member pane's own row
  /// shows for everyone else: this footer used to say `connected` forever
  /// regardless of what was typed into the status menu directly above it.
  final String? activeChannelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final me = ref.watch(meProvider);
    final selfId = ref.watch(sessionProvider).tokens?.userId;
    final voice = ref.watch(voiceFlagsProvider);
    final voiceController = ref.read(voiceControllerProvider.notifier);
    final inCall = voice.state == VoiceSessionState.connected;
    // A call in the channel already on screen has its own full call UI.
    final callChannelId = voice.channelId;
    final inCallElsewhere =
        inCall && callChannelId != null && callChannelId != activeChannelId;

    final statusLabel = ref.watch(ownPresenceProvider).word;
    // A typed status joins the presence word rather than replacing it, so both facts the member pane shows about you show here too (design review note 7).
    final statusText = selfId == null
        ? null
        : ref.watch(statusTextProvider((userId: selfId, snapshot: null)));
    final secondLine = [?statusLabel, ?statusText].join(' · ');

    // Mirrors [RailHeader]: the raised bar and its top border bleed to the
    // screen edge while [SafeArea] lifts the content off the home indicator.
    return Container(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border(top: BorderSide(color: tokens.borderSubtle)),
      ),
      child: SafeArea(
        top: false,
        right: !_railHasNeighbour(context),
        child: Padding(
          key: const Key('rail-footer-padding'),
          // Slimmed from fromLTRB(12, 8, 10, 8) on the owner's own request:
          // AppSpacing has no step between s4 and s8, so s4 is the nearest
          // real reduction rather than a new number.
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s8,
            vertical: AppSpacing.s4,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final controls = [
                ...railVoiceToggleButtons(
                  voice: voice,
                  voiceController: voiceController,
                ),
                if (inCallElsewhere) railLeaveCallButton(voiceController.leave),
                railSettingsButton(context),
              ];
              return Row(
                children: [
                  const PresenceMenuButton(),
                  const SizedBox(width: 9),
                  // At ChannelRail.compactWidth the controls win, scaled down if a notch inset leaves too little; the presence dot still says who and how.
                  if (constraints.maxWidth < _footerNameMinWidth)
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: controls,
                        ),
                      ),
                    )
                  else if (inCallElsewhere)
                    Expanded(
                      child: RailCallSummary(
                        channelId: callChannelId,
                        connectedAt: voice.connectedAt,
                        screenSharing: voice.screenSharing,
                      ),
                    )
                  else
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            me.valueOrNull?.displayName ?? '',
                            overflow: TextOverflow.ellipsis,
                            style: AppText.ui.copyWith(
                              color: tokens.textPrimary,
                              fontWeight: AppWeights.medium,
                              height: 1.25,
                            ),
                          ),
                          Text(
                            secondLine,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.micro.copyWith(
                              color: tokens.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (constraints.maxWidth >= _footerNameMinWidth) ...controls,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
