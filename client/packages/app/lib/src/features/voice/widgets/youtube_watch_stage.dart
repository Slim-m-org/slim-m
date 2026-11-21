// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A YouTube watch party on the call stage: this device's own YouTube player,
/// held on the room's video, position and play state.
///
/// The picture is the web build's iframe or a phone's webview in the stage
/// slot; on desktop the native player lives in the video panel, so the slot
/// says so. Where nothing can play YouTube, the slot offers the browser.
/// See docs/decisions/0050-watch-party-sync-authority-and-direct-play.md and
/// docs/decisions/0128-in-app-youtube-player.md.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../external_link.dart';
import '../../../format.dart' show formatPlaybackTime;
import '../../video/providers/video_host_capability.dart';
import '../../video/providers/video_playback_coordinator.dart';
import '../../video/providers/desktop_video_player.dart';
import '../../video/providers/watch_video_host.dart';
import '../../video/widgets/desktop_video_view.dart';
import '../../video/widgets/video_fullscreen.dart';
import '../providers/watch_room.dart';
import '../providers/youtube_watch_sync.dart';

/// Whether the room on [channelId] is a YouTube party; only asked once a bot is on the call.
bool watchingYoutube(WidgetRef ref, String channelId) => ref.watch(
  watchRoomProvider(
    channelId,
  ).select((r) => r.valueOrNull?.provider == api.WatchProvider.youtube),
);

class YoutubeWatchStage extends ConsumerWidget {
  const YoutubeWatchStage({super.key, required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = ref.watch(videoHostKindProvider).valueOrNull;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.card),
      child: ColoredBox(
        color: Colors.black,
        child: kind == null
            ? const Center(child: AppSpinner())
            : _Body(key: ValueKey(kind), channelId: channelId, kind: kind),
      ),
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body({super.key, required this.channelId, required this.kind});

  final String channelId;
  final VideoHostKind kind;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  final _fullscreen = VideoFullscreenRoute();
  late final ProviderContainer _container;
  late final VideoPlaybackCoordinator _coordinator;
  WatchVideoHandle? _handle;
  YoutubeWatchSync? _sync;
  YoutubeWatchState _state = const YoutubeWatchState();

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    _coordinator = ref.read(videoPlaybackCoordinatorProvider);
    ref.listenManual<AsyncValue<WatchRoom?>>(
      watchRoomProvider(widget.channelId),
      (_, next) => _onRoom(next.valueOrNull),
      fireImmediately: true,
    );
  }

  void _onRoom(WatchRoom? room) {
    if (room == null || room.provider != api.WatchProvider.youtube) return;
    final sync = _sync;
    if (sync != null) {
      unawaited(sync.onRoom(room));
    } else if (_handle == null) {
      _attach(room);
    }
  }

  void _attach(WatchRoom room) {
    final factory = ref.read(watchVideoFactoryProvider(widget.kind));
    if (factory == null) return;
    final clock = ref.read(watchClockProvider);
    final handle = _handle = factory(
      _container,
      videoId: room.itemId,
      start: room.positionAt(clock()),
      title: room.title,
      onShowFullscreen: (view, onExit) =>
          _fullscreen.show(context, view, onExit),
      onHideFullscreen: _fullscreen.hide,
    );
    _coordinator.attach(handle.player);
    final sync = _sync = YoutubeWatchSync(
      player: handle.player,
      load: handle.load,
      clock: clock,
      loadedId: room.itemId,
    );
    sync.onChange((next) {
      if (mounted) setState(() => _state = next);
    });
    unawaited(sync.onRoom(room));
    sync.start();
  }

  Future<void> _detach() async {
    final handle = _handle;
    _sync?.dispose();
    _sync = null;
    _handle = null;
    _state = const YoutubeWatchState();
    if (handle == null) return;
    _coordinator.detach(handle.player);
    await handle.release();
  }

  /// The desktop panel was closed: the party plays there again on request.
  @override
  void dispose() {
    _fullscreen.dispose();
    unawaited(_detach());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final room = ref.watch(watchRoomProvider(widget.channelId)).valueOrNull;
    final url = room == null ? null : youtubeWatchUrl(room.itemId);
    void openOnYoutube() {
      if (url != null) unawaited(openExternalHttpUrl(url));
    }

    final failure = _state.failure;
    if (failure != null) {
      return _Note(
        text: failure.embeddingRefused
            ? 'This video can only be watched on YouTube.'
            : 'This video could not be played here.',
        action: 'Open on YouTube',
        onAction: openOnYoutube,
      );
    }
    final handle = _handle;
    if (handle == null) {
      return _Note(
        text: 'This device cannot play YouTube in the app.',
        action: 'Open on YouTube',
        onAction: openOnYoutube,
      );
    }
    final player = handle.player;
    final view =
        handle.view ??
        (player is DesktopVideoPlayer
            ? DesktopVideoView(player: player)
            : const SizedBox.shrink());
    final localAt = _state.localAt;
    return Stack(
      fit: StackFit.expand,
      children: [
        view,
        if (localAt != null)
          _LocalBand(
            roomAt: localAt,
            onRejoin: () => unawaited(_sync?.rejoin()),
          ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, this.action, this.onAction});

  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final action = this.action;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: AppSpacing.s12,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: Colors.white70),
            ),
            if (action != null)
              AppButton(
                label: action,
                variant: AppButtonVariant.primary,
                size: AppButtonSize.sm,
                onPressed: onAction,
              ),
          ],
        ),
      ),
    );
  }
}

/// This viewer paused, played or seeked on their own; the room carries on.
class _LocalBand extends StatelessWidget {
  const _LocalBand({required this.roomAt, required this.onRejoin});

  final Duration roomAt;
  final VoidCallback onRejoin;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.bottomCenter,
    child: Container(
      constraints: const BoxConstraints(minHeight: AppSizes.rowTouch),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s12,
        vertical: AppSpacing.s8,
      ),
      color: Colors.black87,
      child: Row(
        spacing: AppSpacing.s12,
        children: [
          Expanded(
            child: Text(
              youtubeLocalLine(roomAt),
              style: AppText.caption.copyWith(color: Colors.white),
            ),
          ),
          AppButton(
            label: 'Rejoin the room',
            variant: AppButtonVariant.primary,
            size: AppButtonSize.sm,
            onPressed: onRejoin,
          ),
        ],
      ),
    ),
  );
}

String youtubeLocalLine(Duration roomAt) =>
    'Watching on your own, the room is at ${formatPlaybackTime(roomAt)}';
