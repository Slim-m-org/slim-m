// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail's fixed top and bottom bars: the Space header (with its menu)
/// and the signed-in user's footer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../accounts/providers/account_providers.dart';
import '../../accounts/widgets/account_switcher.dart';
import '../../composer/widgets/voice_recording_marker.dart';
import '../../members/providers/presence_view.dart';
import '../../../providers/providers.dart';
import '../../../providers/server_info.dart';
import '../../members/providers/status_text.dart';
import '../../../providers/sync_controller.dart';
import '../../../sync/providers/sync_failure.dart';
import '../../voice/providers/voice_flags.dart';
import '../../../routing/breakpoints.dart';
import '../../members/widgets/presence_menu.dart';
import 'rail_call_summary.dart';
import 'rail_footer_controls.dart';
import 'rail_notes_button.dart';
import 'space_icon_badge.dart';
import 'space_menu_button.dart';

/// Whether this rail has content beside it, so its own right edge is never
/// the physical screen edge: true at every width the app shows it beside a
/// conversation, false for the one compact case where it fills the screen.
bool _railHasNeighbour(BuildContext context) =>
    LayoutClass.of(context).showsBothPanes;

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
///
/// While offline the dot alone was easy to miss at desktop width, so an
/// "Offline" word sits beside the name (owner decision, 2026-10-26), or
/// "Refused" when the server refused the session; the wide layout still
/// shows no banner.
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
    final failure = ref.watch(syncFailureProvider);
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
                  child: AccountSwitcherTrigger(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SpaceIdentityMark(
                          iconUpdatedAt: server.valueOrNull?.iconUpdatedAt,
                          status: syncStatus,
                          failure: failure,
                        ),
                        Flexible(
                          child: Text(
                            server.valueOrNull?.displayName ?? 'slim-m',
                            overflow: TextOverflow.ellipsis,
                            style: AppText.body.copyWith(
                              color: tokens.textPrimary,
                              fontWeight: AppWeights.semi,
                            ),
                          ),
                        ),
                        if (syncStatus == SyncStatus.offline)
                          Flexible(
                            child: Padding(
                              padding: const EdgeInsets.only(
                                left: AppSpacing.s8,
                              ),
                              child: Text(
                                // A refusal must not read as a retryable offline; the pane below carries the sentence.
                                failure == SyncFailure.refused
                                    ? 'Refused'
                                    : 'Offline',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.caption.copyWith(
                                  color: tokens.warnText,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
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

/// Says plainly whether messages are arriving, under the compact app bar
/// where there is no Space name for `SpaceConnectionDot` to sit beside
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

/// Below this footer width the name line gives way to the controls: avatar,
/// four buttons and their insets leave too little for a readable name.
const double _footerNameMinWidth = 200;

/// Flutter's own gap between a tooltip and the centre of what it names.
const double _tooltipGap = 24;

/// The member's bar at the foot of the rail, under a call row while a call is
/// live anywhere but the channel on screen (decision 0111, 2026-11-16), and
/// under a recording row while a voice message records off screen.
class RailUserFooter extends ConsumerWidget {
  const RailUserFooter({super.key, this.activeChannelId});

  /// The channel currently shown beside or instead of this rail. A call
  /// already live in that channel has its own full call UI, so the call row
  /// (name, duration, leave) is gated on this; mic and deafen are not, since
  /// they control whichever call is live regardless of which channel is on
  /// screen. It is also what lights the Notes button.
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
    final voice = ref.watch(voiceFlagsProvider);
    // A call in the channel already on screen has its own full call UI.
    final callHere =
        voice.callLive &&
        voice.channelId != null &&
        voice.channelId != activeChannelId;
    final otherCommunity = voice.callLive
        ? null
        : ref.watch(accountsSnapshotProvider).callElsewhere;
    final Widget? callRow;
    if (callHere) {
      callRow = const RailCallRow();
    } else if (otherCommunity case final entry?) {
      callRow = RailCommunityCallRow(
        entry: entry,
        switchTo: () async =>
            ref.read(accountHostProvider)?.switchTo(entry.account.origin),
      );
    } else {
      callRow = null;
    }
    final toggles = RailVoiceToggles(otherAccount: otherCommunity?.container);
    final recording = recordingElsewhere(context, ref, activeChannelId);
    return _FooterStack(
      recordingRow: recording == null
          ? null
          : _FooterRow(child: VoiceRecordingRow(channelId: recording)),
      callRow: callRow == null ? null : _FooterRow(child: callRow),
      bar: _FooterRow(
        paddingKey: const Key('rail-footer-padding'),
        safeBottom: true,
        child: _UserBar(toggles: toggles, activeChannelId: activeChannelId),
      ),
    );
  }
}

/// One raised row of the footer. Mirrors [RailHeader]: the fill and its top
/// border bleed to the screen edge while [SafeArea] insets only the content.
class _FooterRow extends StatelessWidget {
  const _FooterRow({
    required this.child,
    this.paddingKey,
    this.safeBottom = false,
  });

  final Widget child;
  final Key? paddingKey;

  /// Only the lowest row lifts its content off the home indicator.
  final bool safeBottom;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border(top: BorderSide(color: tokens.borderSubtle)),
      ),
      child: SafeArea(
        top: false,
        bottom: safeBottom,
        right: !_railHasNeighbour(context),
        child: Padding(
          key: paddingKey,
          // Slimmed from fromLTRB(12, 8, 10, 8) on the owner's own request:
          // AppSpacing has no step between s4 and s8, so s4 is the nearest
          // real reduction rather than a new number.
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s8,
            vertical: AppSpacing.s4,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Avatar, name and status, then mic and deafen in a call, Notes and the gear.
class _UserBar extends ConsumerWidget {
  const _UserBar({required this.toggles, required this.activeChannelId});

  final Widget toggles;
  final String? activeChannelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final me = ref.watch(meProvider);
    final selfId = ref.watch(sessionProvider).tokens?.userId;
    final statusLabel = ref.watch(ownPresenceProvider).word;
    // A typed status joins the presence word rather than replacing it, so both facts the member pane shows about you show here too (design review note 7).
    final statusText = selfId == null
        ? null
        : ref.watch(statusTextProvider((userId: selfId, snapshot: null)));
    final secondLine = [?statusLabel, ?statusText].join(' · ');
    return LayoutBuilder(
      builder: (context, constraints) {
        final controls = [
          toggles,
          RailNotesButton(activeChannelId: activeChannelId),
          railSettingsButton(context),
        ];
        final named = constraints.maxWidth >= _footerNameMinWidth;
        return Row(
          children: [
            const PresenceMenuButton(),
            const SizedBox(width: 9),
            // At ChannelRail.compactWidth the controls win, scaled down if a notch inset leaves too little; the presence dot still says who and how.
            if (!named)
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
            else
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      me.valueOrNull?.displayName ?? '',
                      maxLines: 1,
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
            if (named) ...controls,
          ],
        );
      },
    );
  }
}

/// The recording and call rows over the user bar, with every tooltip opening
/// upward and the bar's lifted clear of the call row, so none covers its Leave.
class _FooterStack extends StatefulWidget {
  const _FooterStack({
    required this.recordingRow,
    required this.callRow,
    required this.bar,
  });

  final Widget? recordingRow;
  final Widget? callRow;
  final Widget bar;

  @override
  State<_FooterStack> createState() => _FooterStackState();
}

class _FooterStackState extends State<_FooterStack> {
  final _callRowKey = GlobalKey();
  double _callRowHeight = 0;

  void _measure(Duration _) {
    if (!mounted) return;
    final box = _callRowKey.currentContext?.findRenderObject() as RenderBox?;
    final height = box != null && box.hasSize ? box.size.height : 0.0;
    if (height != _callRowHeight) setState(() => _callRowHeight = height);
  }

  @override
  Widget build(BuildContext context) {
    final callRow = widget.callRow;
    // The row's height is only known after layout, and a text scale can change it.
    if (callRow != null || _callRowHeight != 0) {
      WidgetsBinding.instance.addPostFrameCallback(_measure);
    }
    final upward = TooltipTheme.of(context).copyWith(preferBelow: false);
    return TooltipTheme(
      data: upward,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?widget.recordingRow,
          if (callRow != null) KeyedSubtree(key: _callRowKey, child: callRow),
          TooltipTheme(
            data: upward.copyWith(
              // The bar's controls sit lower in their taller row, so the extra step keeps the tip off the row's top border.
              verticalOffset:
                  (upward.verticalOffset ?? _tooltipGap) +
                  _callRowHeight +
                  AppSpacing.s4,
            ),
            child: widget.bar,
          ),
        ],
      ),
    );
  }
}
