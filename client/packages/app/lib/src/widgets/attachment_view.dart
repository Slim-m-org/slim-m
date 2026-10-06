// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Renders one attachment: an inline image once its bytes arrive, a real
/// player for a video, or a filename-and-size chip for anything else. The
/// chip and the video player both carry a save action (`attachment_save.dart`)
/// - every attachment this app cannot render inline is still something a
/// user can get out of it.
///
/// An inline image opens fullscreen on tap. The chip does not: only the
/// types the server itself renders inline are images this can display, and a
/// pdf has nothing to show in a zoomable viewer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/app_lifecycle.dart';
import '../providers/attachment_bytes.dart';
import '../providers/attachment_preview_quality.dart';
import '../providers/media_preferences.dart';
import 'attachment_chip.dart';
import 'attachment_format.dart';
import 'attachment_reveal.dart';
import 'attachment_video_player.dart';
import 'image_actions_menu.dart';
import 'run_guarded.dart';
import 'fullscreen_image_viewer.dart';
import 'image_decode.dart';
import 'message_row_parts.dart' show AttachmentPlaceholder;

/// Mirrors `media::is_inline` in `crates/slimm-server/src/media.rs`: the
/// allowlisted types the server serves inline rather than as a forced
/// download. Spelled out rather than tested with a `image/` prefix, because
/// the server's rule is an allowlist too and an unrecognised type falling
/// back to the filename chip is the safe way to be wrong.
const Set<String> inlineImageTypes = {
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
};

bool isInlineImage(String contentType) =>
    inlineImageTypes.contains(contentType);

/// The images on a message, in message order, so opening one fullscreen can
/// page to the rest.
///
/// Only what this client will actually display inline: a pdf or an svg is not
/// a page in a photo gallery, and [AttachmentView] would not open one anyway.
/// It lives beside [isInlineImage] rather than in the row that calls it, so
/// the rule the gallery pages by and the rule a thumbnail renders by are the
/// same rule.
List<api.Attachment> openableImages(List<api.Attachment> attachments) =>
    attachments
        .where((a) => isInlineImage(a.contentType))
        .toList(growable: false);

/// A prefix match, unlike [inlineImageTypes]: there is no server-side
/// allowlist to disagree with here (the server never treats video as
/// inline, so every `video/*` is served as a forced download either way),
/// and unlike Flutter's fixed set of raster codecs, `media_kit`'s player
/// already attempts whatever container/codec its native backend supports.
/// A file this cannot actually decode fails through `Player.stream.error`
/// the same way an undecodable image already fails through [Image]'s own
/// `errorBuilder` - loosely matched here, then handled per-file there.
bool isVideo(String contentType) => contentType.startsWith('video/');

/// The largest an image is drawn inline, in logical pixels, on both axes.
///
/// Half [kMessageColumnMax]. An uncapped preview let one image fill a desktop
/// screen and push the rest of the conversation off it, and the height was
/// unbounded entirely, so a tall narrow image was worse than a wide one.
///
/// Capping both axes rather than the width alone is the point: the transcript
/// is the conversation, and an attachment is a thing in it. Full size is one
/// tap away and already built.
const double kInlineImageMax = kMessageColumnMax / 2;

class AttachmentView extends ConsumerStatefulWidget {
  const AttachmentView({
    super.key,
    required this.attachment,
    this.siblings = const [],
  });

  final api.Attachment attachment;

  /// Every image on the same message, in the order the message shows them,
  /// so opening one fullscreen can page to the rest. Empty for a caller with
  /// nothing to page to, which opens [attachment] alone.
  final List<api.Attachment> siblings;

  @override
  ConsumerState<AttachmentView> createState() => _AttachmentViewState();
}

/// Stateful only for [_heroTag]: an attachment is content-addressed, so one
/// id legitimately rides on more than one message, and two rows showing the
/// same image with one shared tag would throw the moment a flight starts.
/// An identity object held by this element is unique per mounted view and
/// stable across rebuilds, which is exactly what a hero tag needs.
class _AttachmentViewState extends ConsumerState<AttachmentView>
    with GuardedActionState<AttachmentView> {
  final Object _heroTag = Object();

  /// Set once the reader taps a gated preview, opening both gates at once: a
  /// gif held for autoplay, an image held for download, or both, reveal on the
  /// one tap and stay revealed for the life of this row.
  bool _revealed = false;

  /// A pointer resting on a held gif plays it for as long as it stays.
  bool _hovered = false;

  api.Attachment get attachment => widget.attachment;

  bool get _isImage => isInlineImage(attachment.contentType);

  bool get _isGif => attachment.contentType == 'image/gif';

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    if (isVideo(attachment.contentType)) {
      return AttachmentVideoPlayer(attachment: attachment);
    }

    if (!_isImage) {
      return AttachmentChip(attachment: attachment);
    }

    final autoDownload = ref.watch(mediaAutoDownloadControllerProvider);
    final gifAutoplay = ref.watch(gifAutoplayControllerProvider);
    final downloadGated =
        autoDownload == MediaAutoDownload.manual && !_revealed;
    final hoverPlays =
        _isGif && gifAutoplay == GifAutoplay.tapToPlay && !_revealed;
    final playGated = hoverPlays;
    // Whatever the setting, a gif nobody is looking at holds its first frame.
    final still = _isGif && !ref.watch(appFocusedProvider);
    Widget hoverToPlay(Widget child) => hoverPlays
        ? MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: child,
          )
        : child;
    final caption =
        '${attachment.filename} · ${formatByteSize(attachment.size)}';

    // Held for download: nothing fetches until the tap, the point when metered.
    if (downloadGated) {
      return AttachmentRevealTile(
        icon: AppIcons.image,
        line: 'Tap to load',
        caption: caption,
        maxEdge: kInlineImageMax,
        onReveal: () => setState(() => _revealed = true),
      );
    }

    final previewScale = ref
        .watch(attachmentPreviewQualityControllerProvider)
        .decodeScale;
    final decodeWidth = decodeEdge(
      context,
      kInlineImageMax,
      scale: previewScale,
    );
    final bytesAsync = ref.watch(attachmentBytesProvider(attachment.id));
    return bytesAsync.when(
      loading: () => const AttachmentPlaceholder(),
      error: (error, _) => _tappable(
        label: 'Retry loading ${attachment.filename}',
        onTap: () => ref.invalidate(attachmentBytesProvider(attachment.id)),
        child: _FailureBox(
          tokens: tokens,
          message: 'Could not load ${attachment.filename}. Tap to retry.',
          width: 420,
          height: 168,
        ),
      ),
      data: (bytes) {
        // A gif held from autoplay shows its first frame, animating on hover or tap.
        if (playGated) {
          return hoverToPlay(
            AttachmentRevealTile(
              caption: caption,
              maxEdge: kInlineImageMax,
              onReveal: () => setState(() => _revealed = true),
              // The first frame stays mounted under the pointer's playing copy: remounting it re-decodes and resizes the tile.
              showBadge: !_hovered,
              preview: Stack(
                fit: StackFit.passthrough,
                children: [
                  AttachmentFirstFrame(bytes: bytes, cacheWidth: decodeWidth),
                  if (_hovered)
                    Positioned.fill(
                      child: Image.memory(
                        bytes,
                        fit: BoxFit.contain,
                        cacheWidth: decodeWidth,
                      ),
                    ),
                ],
              ),
            ),
          );
        }
        final image = _tappable(
          label: 'Open ${attachment.filename} fullscreen',
          onTap: () {
            final images = widget.siblings.isEmpty
                ? [attachment]
                : widget.siblings;
            final index = images.indexWhere((a) => a.id == attachment.id);
            showFullscreenImage(
              context,
              images: images,
              // A list somehow lacking this attachment would open at -1.
              index: index < 0 ? 0 : index,
              bytes: bytes,
              heroTag: _heroTag,
            );
          },
          // Bordered like the chip and error states beside it (border-first
          // elevation), and captioned: a bare rectangle with no name or size
          // read as decoration rather than a file anyone could open.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Hero(
                tag: _heroTag,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: tokens.borderSubtle),
                    borderRadius: BorderRadius.circular(AppRadii.control),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadii.control),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: kInlineImageMax,
                        maxHeight: kInlineImageMax,
                      ),
                      // Never decodes wider than the transcript can draw it.
                      child: still
                          ? AttachmentFirstFrame(
                              bytes: bytes,
                              cacheWidth: decodeWidth,
                            )
                          : Image.memory(
                              bytes,
                              fit: BoxFit.contain,
                              semanticLabel: attachment.filename,
                              cacheWidth: decodeWidth,
                              // Bytes can decode-fail after a successful fetch; without this it paints as Flutter's raw error box.
                              errorBuilder: (context, error, stackTrace) =>
                                  _FailureBox(
                                    tokens: tokens,
                                    message:
                                        'Could not open ${attachment.filename}.',
                                    width: kInlineImageMax,
                                    height: 168,
                                  ),
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.s4),
              Text(
                caption,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ],
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ImageActionsMenuRegion(
              image: attachment,
              loadBytes: () =>
                  ref.read(attachmentBytesProvider(attachment.id).future),
              onFailure: setActionError,
              child: image,
            ),
            if (actionError != null) ...[
              const SizedBox(height: AppSpacing.s4),
              AppErrorState(message: actionError!, onDismiss: clearActionError),
            ],
          ],
        );
      },
    );
  }

  Widget _tappable({
    required String label,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onTap, child: child),
      ),
    );
  }
}

/// The bordered "something went wrong" placeholder shared by a failed fetch
/// and a fetch that succeeded but handed back bytes the codec refuses to
/// decode - the same box, the same stripe token, so both read as one visual
/// language rather than two.
class _FailureBox extends StatelessWidget {
  const _FailureBox({
    required this.tokens,
    required this.message,
    required this.width,
    required this.height,
  });

  final AppTokens tokens;
  final String message;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tokens.stripe,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Text(message, style: TextStyle(color: tokens.textSecondary)),
    );
  }
}
