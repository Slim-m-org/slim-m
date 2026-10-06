// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Inline playback for a `video/*` attachment: a real player in the
/// transcript rather than a name-and-size chip.
///
/// See `attachment_video_source.dart` for how each platform gets the
/// bearer-token-gated bytes to `package:media_kit`'s player, and
/// `attachment_save.dart` for the save action beside the player - a video
/// that plays but cannot be saved is still only half of what this fixes.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../api_failure.dart';
import '../providers/providers.dart';
import 'attachment_format.dart';
import 'attachment_save.dart';
import 'attachment_video_fullscreen.dart';
import 'attachment_video_reopen.dart';
import 'attachment_video_source.dart' show AttachmentVideoSource;
import 'attachment_video_source_io.dart'
    if (dart.library.js_interop) 'attachment_video_source_web.dart';
import 'run_guarded.dart';
import 'video_playback_controls.dart';

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

class AttachmentVideoPlayer extends ConsumerStatefulWidget {
  const AttachmentVideoPlayer({super.key, required this.attachment});

  final api.Attachment attachment;

  @override
  ConsumerState<AttachmentVideoPlayer> createState() =>
      _AttachmentVideoPlayerState();
}

class _AttachmentVideoPlayerState extends ConsumerState<AttachmentVideoPlayer>
    with GuardedActionState<AttachmentVideoPlayer> {
  final Player _player = Player();
  late final VideoController _videoController = VideoController(_player);
  late final AttachmentVideoSource _source = ref.read(
    attachmentVideoSourceProvider,
  )();

  bool _ready = false;
  bool _saving = false;
  double? _fetchProgress;
  StreamSubscription<String>? _errorSub;
  late final StaleTokenReopener _reopener;

  api.Attachment get attachment => widget.attachment;

  @override
  void initState() {
    super.initState();
    // A decode failure mid-playback surfaces here rather than a thrown Future, since it can fire after open() already succeeded.
    _errorSub = _player.stream.error.listen((_) {
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
    unawaited(_load());
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
      await _player.open(media, play: false);
      if (!mounted) return;
      setState(() => _ready = true);
    } on api.ApiException catch (e) {
      if (mounted) {
        setActionError(describeApiFailure('load ${attachment.filename}', e));
      }
    } catch (_) {
      if (mounted) setActionError('Could not load ${attachment.filename}.');
    }
  }

  Future<void> _openFullscreen() {
    return showFullscreenAttachmentVideo(
      context,
      player: _player,
      controller: _videoController,
      filename: attachment.filename,
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final failure = await saveAttachment(ref, attachment);
    if (!mounted) return;
    setState(() => _saving = false);
    if (failure != null) {
      setActionError(failure);
    } else {
      clearActionError();
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
    final caption =
        '${attachment.filename} · ${formatByteSize(attachment.size)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
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
                    ? VideoPlaybackControls(
                        player: _player,
                        isFullscreen: false,
                        onToggleFullscreen: _openFullscreen,
                        // No default media_kit chrome; see video_playback_controls.dart's doc.
                        child: Video(
                          controller: _videoController,
                          controls: null,
                        ),
                      )
                    : _VideoLoading(progress: _fetchProgress, tokens: tokens),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ),
            const SizedBox(width: AppSpacing.s4),
            _saving
                ? const Padding(
                    padding: EdgeInsets.all(AppSpacing.s4),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : AppIconButton(
                    icon: AppIcons.download,
                    semanticLabel: 'Save ${attachment.filename}',
                    tooltip: 'Save',
                    size: AppIconButtonSize.sm,
                    onPressed: _save,
                  ),
          ],
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
