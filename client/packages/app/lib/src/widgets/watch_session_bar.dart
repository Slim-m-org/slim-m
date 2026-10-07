// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the room is watching and where it is, on the call surface: a title,
/// the playing state, a progress bar and a position readout.
///
/// Reads only. The video is still the bot's shared screen, and this bar does
/// not move it. See
/// docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../format.dart' show formatPlaybackTime;
import '../providers/member_presence.dart' show membersProvider;
import '../providers/watch_room.dart';

/// Mounts [WatchSessionBar] only while a bot is on the call.
///
/// No session is the normal case and the server answers it with a 404, which
/// the browser logs as an error on every call join; a session can only exist
/// while its bot is a participant, so there is nothing to ask before then.
class WatchSessionGate extends ConsumerWidget {
  const WatchSessionGate({
    super.key,
    required this.channelId,
    required this.participantIds,
  });

  final String channelId;
  final Iterable<String> participantIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final present = participantIds.toSet();
    final botOnCall = (ref.watch(membersProvider).valueOrNull ?? const []).any(
      (m) => m.isBot && present.contains(m.id),
    );
    return botOnCall
        ? WatchSessionBar(channelId: channelId)
        : const SizedBox.shrink();
  }
}

class WatchSessionBar extends ConsumerStatefulWidget {
  const WatchSessionBar({super.key, required this.channelId});

  final String channelId;

  @override
  ConsumerState<WatchSessionBar> createState() => _WatchSessionBarState();
}

class _WatchSessionBarState extends ConsumerState<WatchSessionBar> {
  Timer? _second;

  @override
  void initState() {
    super.initState();
    _second = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _second?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final room = ref.watch(watchRoomProvider(widget.channelId)).valueOrNull;
    final now = ref.watch(watchClockProvider)();
    if (room == null || room.isStale(now)) return const SizedBox.shrink();
    final position = room.positionAt(now);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s12),
      child: _Bar(room: room, position: position),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.room, required this.position});

  final WatchRoom room;
  final Duration position;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final duration = room.duration;
    final readout = duration == null
        ? formatPlaybackTime(position)
        : '${formatPlaybackTime(position)} / ${formatPlaybackTime(duration)}';
    final state = room.playing ? 'playing' : 'paused';
    return Semantics(
      container: true,
      label: 'Watching ${room.title}, $state, $readout',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(
            vertical: AppSpacing.s8,
            horizontal: AppSpacing.s12,
          ),
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            border: Border.all(color: tokens.borderSubtle),
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: AppSpacing.s8,
            children: [
              Row(
                spacing: AppSpacing.s8,
                children: [
                  Icon(
                    room.playing ? AppIcons.play : AppIcons.pause,
                    size: AppSizes.icon16,
                    color: tokens.accent,
                  ),
                  Expanded(
                    child: Text(
                      room.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: tokens.textPrimary,
                      ),
                    ),
                  ),
                  Text(
                    readout,
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              if (duration != null && duration > Duration.zero)
                _Progress(
                  fraction: position.inMilliseconds / duration.inMilliseconds,
                  tokens: tokens,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.fraction, required this.tokens});

  final double fraction;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(AppRadii.full),
    child: SizedBox(
      height: AppSpacing.s4,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: tokens.borderSubtle),
          Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: fraction.clamp(0.0, 1.0),
              child: ColoredBox(color: tokens.accentFill),
            ),
          ),
        ],
      ),
    ),
  );
}
