// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Inline playback for a `video/*` attachment: a real player in the
/// transcript rather than a name-and-size chip.
///
/// See `attachment_video_source.dart` for how each platform gets the
/// bearer-token-gated bytes to `package:media_kit`'s player, and
/// `downloads/downloads_controller.dart` for the save action in the player's
/// bar and its right-click menu - a video that plays but cannot be saved is
/// still only half of what this fixes.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../../api_failure.dart';
import '../../../downloads/downloads_controller.dart';
import '../../../providers/app_lifecycle.dart';
import '../../../providers/providers.dart';
import '../../../providers/toasts.dart';
import '../../../widgets/context_menu_region.dart';
import '../../../widgets/viewport_freeze.dart';
import '../../../widgets/attachment_format.dart';
import '../../favorites/providers/favorite_actions.dart';
import '../providers/message_api_actions.dart';
import 'attachment_video_fullscreen.dart';
import 'attachment_video_reopen.dart';
import 'attachment_video_source.dart' show AttachmentVideoSource;
import 'attachment_video_source_io.dart'
    if (dart.library.js_interop) 'attachment_video_source_web.dart';
import '../../../widgets/run_guarded.dart';
import '../../voice/widgets/video_playback_controls.dart';

/// Half [kMessageColumnMax], the same cap an inline image draws under, and
/// the same 16:9 box every shipped platform's player fills as it loads
/// before the real video dimensions are known.
const double kInlineVideoMax = kMessageColumnMax;

/// How each player gets its media, injectable because the real source talks
/// to the network (and, on the web, to `XMLHttpRequest`), which a widget test
/// cannot reach.
final attachmentVideoSourceProvider =
    Provider<AttachmentVideoSource Function()>(
      (ref) => createAttachmentVideoSource,
    );

/// The player each widget plays through, injectable because the real one
/// needs libmpv and a GL texture that a headless test cannot give it.
final attachmentPlayerProvider = Provider<Player Function()>(
  (ref) => Player.new,
);

/// Attaches the render context, injectable because it needs a GL texture.
final attachmentVideoControllerProvider =
    Provider<VideoController Function(Player)>((ref) => VideoController.new);

/// Builds the picture and controls once the player is ready, injectable for
/// the same reason as [attachmentPlayerProvider]: a `Video` needs a GL texture.
typedef AttachmentVideoSurfaceBuilder =
    Widget Function(
      Player player,
      VideoController Function() controller,
      VoidCallback onToggleFullscreen,
      VoidCallback onSave,
      bool saving,
    );

final attachmentVideoSurfaceProvider = Provider<AttachmentVideoSurfaceBuilder>(
  (ref) =>
      (
        player,
        controller,
        onToggleFullscreen,
        onSave,
        saving,
      ) => VideoPlaybackControls(
        player: player,
        isFullscreen: false,
        onToggleFullscreen: onToggleFullscreen,
        onSave: onSave,
        saving: saving,
        // No default media_kit chrome; see video_playback_controls.dart's doc.
        child: Video(controller: controller(), controls: null),
      ),
);

/// Puts a whole video on the clipboard, injectable because the real one talks
/// to the desktop runner.
final clipboardFileWriterProvider = Provider<ClipboardFileWriter>(
  (ref) => const PlatformClipboardFileWriter(),
);

class AttachmentVideoPlayer extends ConsumerStatefulWidget {
  const AttachmentVideoPlayer({
    super.key,
    required this.attachment,
    this.messageId,
  });

  /// The message the video sits on; without one there is nothing to favorite.
  final String? messageId;

  final api.Attachment attachment;

  @override
  ConsumerState<AttachmentVideoPlayer> createState() =>
      _AttachmentVideoPlayerState();
}

class _AttachmentVideoPlayerState extends ConsumerState<AttachmentVideoPlayer>
    with GuardedActionState<AttachmentVideoPlayer> {
  late final Player _player = ref.read(attachmentPlayerProvider)();
  late final VideoController _videoController = ref.read(
    attachmentVideoControllerProvider,
  )(_player);
  late final AttachmentVideoSource _source = ref.read(
    attachmentVideoSourceProvider,
  )();

  bool _ready = false;
  bool _onScreen = false;
  bool _loadStarted = false;
  double? _fetchProgress;
  StreamSubscription<String>? _errorSub;
  late final StaleTokenReopener _reopener;

  api.Attachment get attachment => widget.attachment;

  @override
  void initState() {
    super.initState();
    // A decode failure mid-playback surfaces here rather than a thrown Future, since it can fire after open() already succeeded.
    _errorSub = _player.stream.error.listen((_) {
      if (_reopener.reopenIfStale()) return;
      if (mounted) setActionError('Could not play ${attachment.filename}.');
    });
    _reopener = StaleTokenReopener(
      player: _player,
      source: _source,
      apiClient: ref.read(apiProvider),
      attachment: attachment,
      onFailure: () {
        if (mounted) setActionError('Could not play ${attachment.filename}.');
      },
    )..start();
  }

  /// Opening the source is the expensive part, so it waits until the row is
  /// on screen in a focused window; a row only inside the list's cache extent never pays.
  void _onVisibility(bool visible) {
    _onScreen = visible;
    _syncPlayback();
  }

  void _syncPlayback() {
    final focused = ref.read(appFocusedProvider);
    if (_onScreen && focused) {
      if (!_loadStarted) {
        _loadStarted = true;
        unawaited(_load());
      }
      return;
    }
    // A video covered by its own fullscreen route is still being watched.
    if (_ready && (ModalRoute.isCurrentOf(context) ?? true)) {
      unawaited(_player.pause());
    }
  }

  Future<void> _load() async {
    clearActionError();
    setState(() {
      _ready = false;
      _fetchProgress = null;
    });
    try {
      final media = await _source.open(
        apiClient: ref.read(apiProvider),
        attachment: attachment,
        onProgress: (progress) {
          if (mounted) setState(() => _fetchProgress = progress);
        },
      );
      if (!mounted) return;
      // mpv picks its video output when a file opens, so without a render context first the file plays as audio over black.
      _videoController;
      await _player.open(media, play: false);
      if (!mounted) return;
      setState(() => _ready = true);
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.media, 'load the video', e, stack);
      if (mounted) {
        setActionError(describeApiFailure('load ${attachment.filename}', e));
      }
    } catch (error, stack) {
      api.reportFailure(api.LogTag.media, 'load the video', error, stack);
      if (mounted) setActionError('Could not load ${attachment.filename}.');
    }
  }

  Future<void> _favorite(String messageId) async {
    final failure = await addAttachmentToFavorites(
      ref,
      messageId: messageId,
      attachment: attachment,
    );
    if (failure != null && mounted) setActionError(failure);
  }

  Future<void> _openFullscreen() {
    return showFullscreenAttachmentVideo(
      context,
      player: _player,
      controller: _videoController,
      filename: attachment.filename,
    );
  }

  void _save() {
    clearActionError();
    unawaited(ref.read(downloadsProvider.notifier).start(attachment));
  }

  Future<void> _copy() async {
    clearActionError();
    final actions = ref.read(messageApiActionsProvider);
    final toasts = ref.read(toastsProvider.notifier);
    try {
      await ref
          .read(clipboardFileWriterProvider)
          .writeFile(
            actions.fetchAttachmentBytes(attachment.id),
            filename: attachment.filename,
          );
      toasts.show('Video copied.', severity: AppToastSeverity.success);
    } on ClipboardFileWriteException catch (e, stack) {
      api.AppLog.swallowed(
        api.LogTag.media,
        'Could not copy the video; showing the reason',
        e,
        stack,
      );
      if (mounted) setActionError(e.message);
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.media, 'copy the video', e, stack);
      if (mounted) {
        setActionError(describeApiFailure('copy ${attachment.filename}', e));
      }
    } catch (error, stack) {
      api.reportFailure(api.LogTag.media, 'copy the video', error, stack);
      if (mounted) setActionError('Could not copy ${attachment.filename}.');
    }
  }

  @override
  void dispose() {
    unawaited(_errorSub?.cancel());
    unawaited(_reopener.dispose());
    _player.dispose();
    _source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final saving = ref.watch(
      downloadsProvider.select(
        (tasks) =>
            tasks.any((t) => t.running && t.attachment.id == attachment.id),
      ),
    );
    final caption =
        '${attachment.filename} · ${formatByteSize(attachment.size)}';
    ref.listen(appFocusedProvider, (_, _) => _syncPlayback());

    final canCopy = ref.watch(clipboardFileWriterProvider).supported;

    return ViewportFreeze(
      onVisibility: _onVisibility,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ContextMenuRegion(
            itemsBuilder: (context, close) => [
              if (canCopy)
                AppMenuItem(
                  label: 'Copy video',
                  leading: AppIcons.copy,
                  onTap: () {
                    close();
                    unawaited(_copy());
                  },
                ),
              if (widget.messageId case final id?)
                AppMenuItem(
                  label: 'Add to favorites',
                  leading: AppIcons.favorite,
                  onTap: () {
                    close();
                    unawaited(_favorite(id));
                  },
                ),
              AppMenuItem(
                label: 'Save video',
                leading: AppIcons.download,
                onTap: () {
                  close();
                  _save();
                },
              ),
            ],
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kInlineVideoMax),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.control),
                  child: Container(
                    decoration: BoxDecoration(
                      color: tokens.stripe,
                      border: Border.all(color: tokens.borderSubtle),
                    ),
                    child: _ready
                        ? ref.watch(attachmentVideoSurfaceProvider)(
                            _player,
                            () => _videoController,
                            _openFullscreen,
                            _save,
                            saving,
                          )
                        : _VideoLoading(
                            progress: _fetchProgress,
                            tokens: tokens,
                          ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
          if (actionError != null) ...[
            const SizedBox(height: AppSpacing.s4),
            AppErrorState(
              message: actionError!,
              onRetry: _ready ? null : _load,
              onDismiss: clearActionError,
            ),
          ],
        ],
      ),
    );
  }
}

/// What the 16:9 frame shows before `Player.open` resolves - a still poster
/// glyph plus whatever load signal is available, never an indeterminate
/// spinner: a widget test that pumps this state must be able to settle, and
/// an [AnimationController] that never completes is exactly what a bare
/// [CircularProgressIndicator] would install here.
///
/// Web tracks bytes fetched against the attachment's known size, so
/// [progress] is a real fraction there; native platforms hand the URL
/// straight to libmpv's own streaming reader, which has no comparable count
/// to report, so [progress] stays null and the label carries the state
/// instead.
class _VideoLoading extends StatelessWidget {
  const _VideoLoading({required this.progress, required this.tokens});

  final double? progress;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.play, size: 28, color: tokens.textSecondary),
            const SizedBox(height: AppSpacing.s8),
            if (progress != null)
              SizedBox(
                width: 120,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.full),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                    backgroundColor: tokens.surfaceSunken,
                    color: tokens.accentFill,
                  ),
                ),
              )
            else
              Text(
                'Loading video…',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
          ],
        ),
      ),
    );
  }
}
