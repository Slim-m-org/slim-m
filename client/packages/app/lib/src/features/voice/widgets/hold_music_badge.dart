// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The floating "music while alone" badge: style pick, timeline, play and
/// pause, and a vertical volume slider that unfolds above it.
///
/// Drawn only on a wide window while you are the only one in the call
/// (desktop-vs-mobile.md rules 1 and 2: width decides, and the style pick is
/// a dropdown for a control that stays on screen). A compact window keeps the
/// dock button and the mic-menu rows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../audio/hold_music_player.dart';
import '../../../audio/lounge_tracks.dart';
import '../../../widgets/context_menu_region.dart';
import '../providers/call_solo.dart';
import '../providers/hold_music_actions.dart';
import '../providers/hold_music_controller.dart';
import '../providers/voice_settings_controller.dart';
import '../../../providers/dock_reservation.dart';

const _musicVolumeLabel = 'Music volume';

/// Pins the badge to the bottom-left of a call surface, [bottom] above its edge so it clears the dock.
/// Sits in the dock's own row when the window leaves room beside it, else above the dock.
class HoldMusicBadgeOverlay extends ConsumerStatefulWidget {
  const HoldMusicBadgeOverlay({
    super.key,
    required this.fallbackBottom,
    this.dockHeight,
    this.dockWidth,
    this.dockMargin = AppSpacing.s12,
  });

  /// Where the badge sits when it cannot share the dock's row.
  final double fallbackBottom;

  /// The dock's measured height, or null before it has been laid out.
  final double? dockHeight;

  /// The dock's measured width; the shared dock's published width when null.
  final double? dockWidth;

  /// The gap between the dock and the bottom edge.
  final double dockMargin;

  @override
  ConsumerState<HoldMusicBadgeOverlay> createState() =>
      _HoldMusicBadgeOverlayState();
}

class _HoldMusicBadgeOverlayState extends ConsumerState<HoldMusicBadgeOverlay> {
  final _badgeKey = GlobalKey();
  double? _badgeWidth;

  void _measure() {
    final width = _badgeKey.currentContext?.size?.width;
    if (mounted && width != null && width != _badgeWidth) {
      setState(() => _badgeWidth = width);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown =
        ref.watch(holdMusicAvailableProvider) &&
        ref.watch(callAloneProvider) &&
        holdMusicBadgeFits(context);
    if (!shown) return const SizedBox.shrink();
    final sharedDockWidth = ref.watch(bottomDockWidthProvider);
    final double dockWidth = widget.dockWidth ?? sharedDockWidth;
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    final badge = KeyedSubtree(key: _badgeKey, child: const HoldMusicBadge());
    return LayoutBuilder(
      builder: (context, constraints) {
        final dockHeight = widget.dockHeight;
        final badgeWidth = _badgeWidth;
        final room = (constraints.maxWidth - dockWidth) / 2;
        final beside =
            dockHeight != null &&
            dockHeight > 0 &&
            dockWidth > 0 &&
            badgeWidth != null &&
            room >= badgeWidth + AppSpacing.s12 * 2;
        return Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: EdgeInsets.only(
              left: AppSpacing.s12,
              bottom: beside ? widget.dockMargin : widget.fallbackBottom,
            ),
            child: beside
                ? SizedBox(
                    height: dockHeight,
                    child: Align(alignment: Alignment.centerLeft, child: badge),
                  )
                : badge,
          ),
        );
      },
    );
  }
}

class HoldMusicBadge extends ConsumerStatefulWidget {
  const HoldMusicBadge({super.key});

  @override
  ConsumerState<HoldMusicBadge> createState() => _HoldMusicBadgeState();
}

class _HoldMusicBadgeState extends ConsumerState<HoldMusicBadge> {
  final _styleMenu = GlobalKey<ContextMenuRegionState>();
  bool _volumeOpen = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final settings = ref.watch(voiceSettingsControllerProvider);
    final player = ref.watch(holdMusicPlayerProvider);
    final paused = ref.watch(holdMusicPausedProvider);
    final on = settings.holdMusicEnabled && !paused;
    return Semantics(
      container: true,
      label: 'Music player',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          AnimatedSize(
            duration: AppMotion.reducedSize(context, AppMotion.base),
            curve: AppMotion.entrance,
            alignment: Alignment.bottomCenter,
            child: _volumeOpen
                ? _volumePanel(tokens, settings.holdMusicVolume)
                : const SizedBox(width: AppSizes.controlSm),
          ),
          if (_volumeOpen) const SizedBox(height: AppSpacing.s4),
          _pill(tokens, settings, player, on),
        ],
      ),
    );
  }

  /// Pauses or resumes the track in place; with music turned off it turns it on.
  void _playOrPause(bool enabled) {
    final controller = ref.read(holdMusicControllerProvider);
    if (!enabled) {
      toggleHoldMusic(ref);
    } else if (ref.read(holdMusicPausedProvider)) {
      controller.resume();
    } else {
      controller.pause();
    }
  }

  Widget _pill(
    AppTokens tokens,
    VoiceSettingsState settings,
    HoldMusicPlayer player,
    bool on,
  ) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.s8,
      vertical: AppSpacing.s4,
    ),
    decoration: BoxDecoration(
      color: tokens.surfaceRaised,
      borderRadius: BorderRadius.circular(AppRadii.full),
      border: Border.all(color: tokens.borderSubtle),
      boxShadow: AppShadows.canvasTile,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _styleButton(settings.holdMusicTrack),
        const SizedBox(width: AppSpacing.s4),
        _Timeline(player: player, on: on),
        const SizedBox(width: AppSpacing.s4),
        AppIconButton(
          icon: on ? AppIcons.pause : AppIcons.play,
          semanticLabel: on ? 'Pause music' : 'Play music',
          tooltip: on ? 'Pause music' : 'Play music',
          size: AppIconButtonSize.sm,
          iconSize: AppSizes.icon16,
          onPressed: () => _playOrPause(settings.holdMusicEnabled),
        ),
        AppIconButton(
          icon: settings.holdMusicVolume == 0
              ? AppIcons.speakerOff
              : AppIcons.speaker,
          semanticLabel: _volumeOpen ? 'Hide music volume' : _musicVolumeLabel,
          tooltip: _musicVolumeLabel,
          size: AppIconButtonSize.sm,
          iconSize: AppSizes.icon16,
          active: _volumeOpen,
          onPressed: () => setState(() => _volumeOpen = !_volumeOpen),
        ),
      ],
    ),
  );

  Widget _styleButton(LoungeTrack track) => ContextMenuRegion(
    key: _styleMenu,
    ownsFocusNode: false,
    opensAbove: true,
    itemsBuilder: (context, close) => [
      const AppMenuLabel('Style'),
      for (final style in LoungeTrack.values)
        AppMenuItem(
          label: style.style,
          selected: style == track,
          onTap: () {
            close();
            pickHoldMusicTrack(ref, style);
          },
        ),
      AppMenuItem(
        label: 'Next track',
        leading: AppIcons.callSkipNext,
        onTap: () {
          close();
          pickHoldMusicTrack(ref, track.next);
        },
      ),
    ],
    child: AppIconButton(
      icon: AppIcons.music,
      semanticLabel: 'Music style, ${track.style}',
      tooltip: '${track.style}: ${track.title}',
      size: AppIconButtonSize.sm,
      iconSize: AppSizes.icon16,
      onPressed: () => _styleMenu.currentState?.toggle(),
    ),
  );

  Widget _volumePanel(AppTokens tokens, double volume) => Container(
    width: AppSizes.controlSm + AppSpacing.s8,
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.s8),
    decoration: BoxDecoration(
      color: tokens.surfaceRaised,
      borderRadius: BorderRadius.circular(AppRadii.full),
      border: Border.all(color: tokens.borderSubtle),
      boxShadow: AppShadows.canvasTile,
    ),
    child: RotatedBox(
      quarterTurns: 3,
      child: SizedBox(
        width: _volumeTrackLength,
        child: AppSlider(
          value: volume * 100,
          semanticLabel: _musicVolumeLabel,
          valueLabel: (v) => '${v.round()}%',
          onChanged: (v) => ref
              .read(voiceSettingsControllerProvider.notifier)
              .setHoldMusicVolume(v / 100),
        ),
      ),
    ),
  );
}

const double _volumeTrackLength = 96;
const double _timelineWidth = 96;

/// The elapsed bar and "0:00 / 2:34"; dragging it seeks.
class _Timeline extends StatefulWidget {
  const _Timeline({required this.player, required this.on});

  final HoldMusicPlayer player;
  final bool on;

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  /// The thumb's place mid-drag, so it follows the finger instead of the playhead.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ValueListenableBuilder<HoldPlayback>(
      valueListenable: widget.player.playback,
      builder: (context, playback, _) {
        final total = playback.duration;
        final seekable = widget.on && total != null && total > Duration.zero;
        final millis = (total?.inMilliseconds ?? 1).toDouble();
        final elapsed = playback.position.inMilliseconds.clamp(0, millis);
        final shown = Duration(milliseconds: (_dragging ?? elapsed).round());
        final label =
            '${formatClock(shown)} / ${total == null ? '-:--' : formatClock(total)}';
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: _timelineWidth,
              child: AppSlider(
                value: (_dragging ?? elapsed).toDouble(),
                max: millis,
                semanticLabel: 'Music position',
                valueLabel: (_) => label,
                onChanged: seekable
                    ? (v) => setState(() => _dragging = v)
                    : null,
                onChangeEnd: seekable
                    ? (v) {
                        setState(() => _dragging = null);
                        widget.player.seek(Duration(milliseconds: v.round()));
                      }
                    : null,
              ),
            ),
            const SizedBox(width: AppSpacing.s4),
            Text(
              label,
              maxLines: 1,
              style: AppText.caption.copyWith(
                color: tokens.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// `m:ss`, for a track that runs minutes.
String formatClock(Duration d) {
  final seconds = d.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
