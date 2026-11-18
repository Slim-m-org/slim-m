// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The in-call surface: a header, the banners, and one stage that fits every
/// share, camera and audio-only person into the room that is left.
///
/// The fit lives in `../layout/stage_fit.dart` and is placed by
/// [CallStageFitView]; see decision 0114. A share's pin lives in
/// `shareWatchProvider`: pinned, else the newest share is the largest tile.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../widgets/status_banner.dart';
import '../providers/direct_play_provider.dart';
import '../providers/share_watch.dart';
import '../providers/voice_health.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../providers/call_roster_gap.dart';
import 'call_audio_banner.dart';
import 'call_gap_banner.dart';
import 'call_header_facts.dart';
import 'call_stage_fit_view.dart';
import 'local_screen_share_banner.dart';
import 'mic_failure_banner.dart';
import 'poor_connection_banner.dart';
import 'voice_reconnect_banner.dart';
import 'direct_play_stage.dart';
import 'watch_session_bar.dart';

export 'participant_tile_builder.dart' show participantTile;

/// The dock's own visible height plus its margin, so the last row of
/// content reserves room rather than have the floating card cover it.
const double _dockClearance = 76;

/// The clearance a caller that does not measure its dock gets.
const double defaultDockClearance = _dockClearance;

/// The whole in-call body: a compact header, then the fitted stage.
class CallStageLayout extends ConsumerWidget {
  const CallStageLayout({
    super.key,
    required this.controller,
    required this.onOpenProfile,
    required this.isDm,
    this.menuItemsBuilder,
    this.dockClearance = _dockClearance,
  });

  /// How much of the bottom edge the call's dock covers, measured by the
  /// caller where the dock's height varies (a phone with bot controls).
  final double dockClearance;

  final VoiceController controller;

  /// [BuildContext] is the tapped tile's own - the anchor a popover opened
  /// from it has to hang off, not the screen's outer context every tile
  /// shares. Passing the wrong one pins the popover wherever that outer
  /// context happens to render instead of beside the tile that was tapped.
  final void Function(BuildContext anchor, VoiceParticipant participant)
  onOpenProfile;

  /// A DM has no member list, so the alone hint is withheld.
  final bool isDm;

  /// A tile's own right-click/long-press quick-actions rows, bound to the
  /// participant [participantTile] builds each tile for -
  /// `participant_call_menu.dart`'s own `participantCallMenuItems`, shared
  /// with the canvas bubble's own context menu.
  final List<Widget> Function(
    BuildContext context,
    VoiceParticipant participant,
    VoidCallback close, {
    bool withStreams,
  })?
  menuItemsBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voice = ref.watch(voiceFlagsProvider);
    // The roster without speaking flags: a talker flipping must not rebuild the stage, only their tile's ring.
    final participants = ref.watch(voiceSilentRosterProvider);
    final gap = ref.watch(callRosterGapProvider);
    final watch = ref.watch(shareWatchProvider);
    final watching = ref.read(shareWatchProvider.notifier);
    final shares = activeShares(
      participants,
      stopped: watch.stopped,
      focusedIdentity: watch.focused,
    );
    final channelId = voice.channelId;
    final playingDirect =
        !isDm &&
        channelId != null &&
        botIsOnCall(ref, [for (final p in participants) p.identity]) &&
        ref.watch(directPlayProvider(channelId).select((d) => d.active));
    final directStage = playingDirect
        ? DirectPlayStage(channelId: channelId)
        : null;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s16,
        AppSpacing.s16,
        AppSpacing.s16,
        AppSpacing.s16 + dockClearance,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CallHeader(channelId: voice.channelId),
          // One banner at a time: the reconnect notice already says why the stage is quiet.
          if (voice.rejoining || voice.reconnecting)
            VoiceReconnectBanner(
              mediaDown:
                  voice.rejoining ||
                  gap.selfMissing ||
                  ref.watch(voiceRestartingProvider),
            )
          else
            const CallGapBanner(child: PoorConnectionBanner()),
          if (!isDm && voice.channelId != null)
            WatchSessionGate(
              channelId: voice.channelId!,
              participantIds: [for (final p in participants) p.identity],
            ),
          // A live share has no banner: the share control and the stage caption say it (decision 0047, point 8).
          if (voice.awaitingBroadcast) const LocalScreenSharePendingBanner(),
          if (!isDm && voice.channelId != null)
            CallAudioBanner(channelId: voice.channelId!),
          if (voice.error != null && !voice.rejoining && !voice.reconnecting)
            StatusBanner(
              severity: BannerSeverity.error,
              sticky: true,
              message: voice.error!,
              margin: const EdgeInsets.only(top: AppSpacing.s12),
            ),
          const MicFailureBanner(),
          const SizedBox(height: AppSpacing.s12),
          Expanded(
            child: CallStageFitView(
              participants: withPendingPeers(participants, gap.connecting),
              shares: shares,
              focused: watch.focused,
              directStage: directStage,
              controller: controller,
              onOpenProfile: onOpenProfile,
              onStopWatching: watching.stop,
              onFocus: watching.focus,
              menuItemsBuilder: menuItemsBuilder,
            ),
          ),
        ],
      ),
    );
  }
}

/// [shown] with a connecting tile for each of [pending], after everyone the call delivered.
List<VoiceParticipant> withPendingPeers(
  List<VoiceParticipant> shown,
  List<PendingPeer> pending,
) => pending.isEmpty
    ? shown
    : [
        ...shown,
        for (final p in pending)
          VoiceParticipant(
            identity: p.id,
            name: p.name,
            isSpeaking: false,
            isMuted: true,
            isLocal: false,
            isScreenSharing: false,
            presence: CallPresence.connecting,
          ),
      ];

class _CallHeader extends StatelessWidget {
  const _CallHeader({required this.channelId});

  final String? channelId;

  @override
  Widget build(BuildContext context) {
    final channelId = this.channelId;
    if (channelId == null) return const SizedBox.shrink();
    return CallHeaderLine(channelId: channelId, showTitle: false);
  }
}
