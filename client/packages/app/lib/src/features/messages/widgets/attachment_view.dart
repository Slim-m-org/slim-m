// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Renders one attachment: an inline image once its bytes arrive, a real
/// player for a video, or a filename-and-size chip for anything else. The
/// chip and the video player both carry a save action (`downloads/downloads_controller.dart`)
/// - every attachment this app cannot render inline is still something a
/// user can get out of it.
///
/// An inline image opens fullscreen on tap. The chip does not: only the
/// types the server itself renders inline are images this can display, and a
/// pdf has nothing to show in a zoomable viewer.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/app_lifecycle.dart';
import '../providers/attachment_bytes.dart';
import '../providers/attachment_preview_bytes.dart';
import '../providers/attachment_preview_quality.dart';
import '../providers/media_preferences.dart';
import 'attachment_chip.dart';
import 'attachment_format.dart';
import 'attachment_image_states.dart';
import 'attachment_reveal.dart';
import 'attachment_spoiler.dart';
import 'attachment_types.dart';
import 'attachment_video_player.dart';
import 'image_actions_menu.dart';
import '../../../widgets/run_guarded.dart';
import 'fullscreen_image_viewer.dart';
import 'image_decode.dart';
import '../../../widgets/animation_gate.dart';

export 'attachment_types.dart';

class AttachmentView extends ConsumerStatefulWidget {
  const AttachmentView({
    super.key,
    required this.attachment,
    this.siblings = const [],
    this.tileEdge,
    this.moreCount = 0,
  });

  final api.Attachment attachment;

  /// Every image on the same message, in the order the message shows them,
  /// so opening one fullscreen can page to the rest. Empty for a caller with
  /// nothing to page to, which opens [attachment] alone.
  final List<api.Attachment> siblings;

  /// Set by [AttachmentGallery]: an image drawn as a square tile of this edge,
  /// cropped to fill and uncaptioned, instead of at its own aspect.
  final double? tileEdge;

  /// How many more images a gallery holds past this, its last visible tile.
  final int moreCount;

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

  /// Set once the reader looks behind a spoiler, for the life of this row.
  bool _spoilerRevealed = false;

  api.Attachment get attachment => widget.attachment;

  bool get _isImage => isInlineImage(attachment.contentType);

  bool get _isGif => attachment.contentType == 'image/gif';

  @override
  Widget build(BuildContext context) {
    final body = _body(context);
    if (!attachment.spoiler || _spoilerRevealed) return body;
    return AttachmentSpoilerCover(
      filename: attachment.filename,
      onReveal: () => setState(() => _spoilerRevealed = true),
      child: body,
    );
  }

  Widget _body(BuildContext context) {
    final autoDownload = ref.watch(mediaAutoDownloadControllerProvider);
    final downloadGated =
        autoDownload == MediaAutoDownload.manual && !_revealed;
    if (isVideo(attachment.contentType)) return _video(downloadGated);
    if (!_isImage) return AttachmentChip(attachment: attachment);
    return _image(context, downloadGated: downloadGated);
  }

  String get _caption =>
      '${attachment.filename} · ${formatByteSize(attachment.size)}';

  void _reveal() => setState(() => _revealed = true);

  Widget _video(bool downloadGated) {
    // A player opens its source on mount, so the manual setting holds it back too.
    if (!downloadGated) return AttachmentVideoPlayer(attachment: attachment);
    return AttachmentRevealTile(
      icon: AppIcons.play,
      line: 'Tap to load',
      caption: _caption,
      maxEdge: kInlineVideoMax,
      onReveal: _reveal,
    );
  }

  Widget _image(BuildContext context, {required bool downloadGated}) {
    final tile = widget.tileEdge;
    final gifAutoplay = ref.watch(gifAutoplayControllerProvider);
    final focused = ref.watch(appFocusedProvider);
    final caption = _caption;

    // Held for download: nothing fetches until the tap, the point when metered.
    if (downloadGated) {
      return AttachmentRevealTile(
        icon: AppIcons.image,
        line: 'Tap to load',
        caption: caption,
        maxEdge: tile ?? kInlineImageMax,
        onReveal: _reveal,
      );
    }

    final previewScale = ref
        .watch(attachmentPreviewQualityControllerProvider)
        .decodeScale;
    final decodeWidth = decodeEdge(
      context,
      tile ?? kInlineImageMax,
      scale: previewScale,
    );
    // A gif answers its first frame; the original is fetched only once it plays.
    final bytesAsync = ref.watch(
      attachmentPreviewBytesProvider((
        id: attachment.id,
        bucket: attachmentPreviewBucket(decodeWidth),
      )),
    );
    return bytesAsync.when(
      loading: () => _captioned(
        caption,
        AttachmentLoadingBox(
          filename: attachment.filename,
          width: kInlineImageMax,
          tileEdge: tile,
        ),
      ),
      error: (error, _) => _captioned(
        caption,
        AttachmentFailureBox(
          filename: attachment.filename,
          width: kInlineImageMax,
          tileEdge: tile,
          onRetry: () => _refetch(decodeWidth),
        ),
      ),
      data: (bytes) {
        final animated = _isGif || looksAnimated(bytes);
        final standIn = _isGif && !looksAnimated(bytes);
        final playGated =
            animated && gifAutoplay == GifAutoplay.tapToPlay && !_revealed;
        // Whatever the setting, an animation nobody is looking at holds its first frame.
        final still = animated && !focused;
        // An animation held from autoplay shows its first frame, animating on hover or tap.
        if (playGated) {
          return _gatedGif(
            bytes,
            playBytes: standIn && _hovered ? _original(bytes) : bytes,
            caption: caption,
            decodeWidth: decodeWidth,
          );
        }
        return _openableImage(
          standIn && !still ? _original(bytes) : bytes,
          caption: caption,
          decodeWidth: decodeWidth,
          still: still,
        );
      },
    );
  }

  /// The moving original once it has arrived, the first frame until then.
  Uint8List _original(Uint8List firstFrame) =>
      ref.watch(attachmentBytesProvider(attachment.id)).valueOrNull ??
      firstFrame;

  Widget _gatedGif(
    Uint8List bytes, {
    required Uint8List playBytes,
    required String caption,
    required int decodeWidth,
  }) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AttachmentRevealTile(
        caption: caption,
        maxEdge: widget.tileEdge ?? kInlineImageMax,
        onReveal: _reveal,
        // The first frame stays mounted under the pointer's playing copy: remounting it re-decodes and resizes the tile.
        showBadge: !_hovered,
        preview: AnimationGate(
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              AttachmentFirstFrame(bytes: bytes, cacheWidth: decodeWidth),
              if (_hovered)
                Positioned.fill(
                  child: Image.memory(
                    playBytes,
                    fit: BoxFit.contain,
                    cacheWidth: decodeWidth,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _openableImage(
    Uint8List bytes, {
    required String caption,
    required int decodeWidth,
    required bool still,
  }) {
    final image = _tappable(
      label: 'Open ${attachment.filename} fullscreen',
      onTap: () => _openFullscreen(bytes),
      child: _imageColumn(
        bytes,
        caption: caption,
        decodeWidth: decodeWidth,
        still: still,
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
          child: _withMoreOverlay(image),
        ),
        if (actionError != null) ...[
          const SizedBox(height: AppSpacing.s4),
          AppErrorState(message: actionError!, onDismiss: clearActionError),
        ],
      ],
    );
  }

  Widget _withMoreOverlay(Widget image) {
    if (widget.moreCount <= 0) return image;
    return Stack(
      children: [
        image,
        Positioned.fill(child: _MoreOverlay(count: widget.moreCount)),
      ],
    );
  }

  void _openFullscreen(Uint8List bytes) {
    // Paging must never land on a spoiler nobody chose to look at.
    final images = widget.siblings.isEmpty
        ? [attachment]
        : widget.siblings
              .where((a) => !a.spoiler || a.id == attachment.id)
              .toList();
    final index = images.indexWhere((a) => a.id == attachment.id);
    showFullscreenImage(
      context,
      images: images,
      // A list somehow lacking this attachment would open at -1.
      index: index < 0 ? 0 : index,
      bytes: bytes,
      heroTag: _heroTag,
    );
  }

  // Bordered like the chip and error states beside it, and captioned: a bare rectangle read as decoration.
  Widget _imageColumn(
    Uint8List bytes, {
    required String caption,
    required int decodeWidth,
    required bool still,
  }) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final tile = widget.tileEdge;
    return Column(
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
                constraints: _imageConstraints(tile),
                // Never decodes wider than the transcript can draw it.
                child: AnimationGate(
                  child: _bitmap(bytes, decodeWidth: decodeWidth, still: still),
                ),
              ),
            ),
          ),
        ),
        if (tile == null) ...[
          const SizedBox(height: AppSpacing.s4),
          Text(
            caption,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ],
      ],
    );
  }

  BoxConstraints _imageConstraints(double? tile) {
    if (tile == null) {
      return const BoxConstraints(
        maxWidth: kInlineImageMax,
        maxHeight: kInlineImageMax,
      );
    }
    // The tile's 1px border sits outside the image, so the image gives it back.
    return BoxConstraints.tight(Size.square(tile - 2));
  }

  Widget _bitmap(
    Uint8List bytes, {
    required int decodeWidth,
    required bool still,
  }) {
    if (still) {
      return AttachmentFirstFrame(bytes: bytes, cacheWidth: decodeWidth);
    }
    final tile = widget.tileEdge;
    return Image.memory(
      bytes,
      fit: tile == null ? BoxFit.contain : BoxFit.cover,
      semanticLabel: attachment.filename,
      cacheWidth: decodeWidth,
      // Bytes can decode-fail after a successful fetch; without this it paints as Flutter's raw error box.
      errorBuilder: (context, error, stackTrace) => AttachmentFailureBox(
        filename: attachment.filename,
        width: kInlineImageMax,
        tileEdge: tile,
        message: 'Could not open',
        onRetry: () => _refetch(decodeWidth),
      ),
    );
  }

  void _refetch(int decodeWidth) {
    ref.invalidate(attachmentBytesProvider(attachment.id));
    ref.invalidate(
      attachmentPreviewBytesProvider((
        id: attachment.id,
        bucket: attachmentPreviewBucket(decodeWidth),
      )),
    );
  }

  /// The real preview's caption under a stand-in, so nothing shifts on arrival.
  Widget _captioned(String caption, Widget box) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    if (widget.tileEdge != null) return box;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        box,
        const SizedBox(height: AppSpacing.s4),
        Text(
          caption,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      ],
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

/// "+3" over a gallery's last tile, for the images it has no room to show;
/// the tap still opens the viewer, which pages through all of them.
class _MoreOverlay extends StatelessWidget {
  const _MoreOverlay({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return IgnorePointer(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: ColoredBox(
          color: tokens.surfaceBase.withValues(alpha: 0.7),
          child: Center(
            child: Text(
              '+$count',
              style: AppText.title.copyWith(color: tokens.textPrimary),
            ),
          ),
        ),
      ),
    );
  }
}
