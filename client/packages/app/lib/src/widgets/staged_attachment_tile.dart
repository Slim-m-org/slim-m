// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tile a staged attachment renders into: a thumbnail or file glyph, its
/// name, its upload state, and the controls to remove or retry it.
///
/// Split out of `composer_attachments.dart`, which holds the model this
/// draws rather than any widget, so that file stays usable from a plain
/// unit test with no Flutter binding at all.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_attachments.dart';
import 'image_decode.dart';
import 'transfer_meter.dart';

/// The square a thumbnail or a generic-file glyph draws into.
const double _thumbnailSize = AppSpacing.s40;

/// One staged attachment: a thumbnail or file glyph, its name, its upload
/// state, and the controls to remove or retry it.
///
/// One widget for every kind of attachment and every state, rather than a
/// chip for a ready file and something else for a pending or failed one, so
/// a state change is a rebuild in place instead of a different widget
/// mounting where the old one was.
class StagedAttachmentTile extends StatelessWidget {
  const StagedAttachmentTile({
    super.key,
    required this.attachment,
    required this.onRemove,
    required this.onRetry,
    this.spoiler = false,
    this.onToggleSpoiler,
  });

  final StagedAttachment attachment;
  final VoidCallback onRemove;
  final VoidCallback onRetry;

  /// Whether this will be sent behind a spoiler.
  final bool spoiler;

  /// Null for a file that cannot be a spoiler, which hides the control.
  final VoidCallback? onToggleSpoiler;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final a = attachment;
    final failed = a is FailedAttachment;
    Widget? statusLine;
    if (a is UploadingAttachment) {
      statusLine = _UploadProgress(upload: a);
    } else if (a is FailedAttachment) {
      statusLine = Text(
        a.message,
        style: AppText.caption.copyWith(color: tokens.dangerText),
      );
    }
    return Container(
      padding: const EdgeInsets.only(
        left: 4,
        top: 4,
        bottom: 4,
        right: AppSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border.all(
          color: failed ? tokens.dangerBorder : tokens.borderSubtle,
        ),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _AttachmentThumbnail(attachment: a, spoiler: spoiler),
          const SizedBox(width: AppSpacing.s8),
          // A failure or a progress line reads in full, so its column may grow; it still shrinks to the row.
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: failed || a is UploadingAttachment ? 300 : 180,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    a.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: failed ? tokens.dangerText : tokens.textPrimary,
                    ),
                  ),
                  if (statusLine != null) statusLine,
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.s8),
          if (onToggleSpoiler case final toggle?)
            _TileButton(
              icon: AppIcons.spoiler,
              semanticLabel: spoiler
                  ? 'Show ${a.filename} without a spoiler'
                  : 'Mark ${a.filename} as a spoiler',
              tooltip: spoiler ? 'Remove spoiler' : 'Mark as spoiler',
              active: spoiler,
              onTap: toggle,
            ),
          if (failed)
            _TileButton(
              icon: AppIcons.retry,
              semanticLabel: 'Retry attaching ${a.filename}',
              onTap: onRetry,
            ),
          _TileButton(
            icon: AppIcons.dismiss,
            semanticLabel: 'Remove attachment ${a.filename}',
            onTap: onRemove,
          ),
        ],
      ),
    );
  }
}

/// The progress line and a bar for an upload in flight: percent, speed and
/// time left once the rate is stable, so a multi-gigabyte file shows it is
/// moving and when it will finish.
class _UploadProgress extends StatelessWidget {
  const _UploadProgress({required this.upload});

  final UploadingAttachment upload;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final percent = (upload.fraction * 100).floor();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          formatTransferLine(
            sent: upload.sent,
            total: upload.body.length,
            meter: upload.meter,
            reconnecting: upload.reconnecting,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s4),
        LinearProgressIndicator(
          value: upload.fraction,
          minHeight: 3,
          semanticsLabel: 'Uploading ${upload.filename}',
          semanticsValue: '$percent%',
        ),
      ],
    );
  }
}

class _AttachmentThumbnail extends StatelessWidget {
  const _AttachmentThumbnail({required this.attachment, required this.spoiler});

  final StagedAttachment attachment;
  final bool spoiler;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final bytes = attachment.bytes;
    final showImage = bytes != null && looksLikeImage(attachment.filename);
    return SizedBox(
      width: _thumbnailSize,
      height: _thumbnailSize,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.control),
              child: ColoredBox(
                color: tokens.surfaceBase,
                child: showImage
                    ? ImageFiltered(
                        enabled: spoiler,
                        imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                        child: Image.memory(
                          bytes,
                          fit: BoxFit.cover,
                          cacheWidth: decodeEdge(context, _thumbnailSize),
                          cacheHeight: decodeEdge(context, _thumbnailSize),
                          errorBuilder: (_, _, _) => _fileGlyph(tokens),
                        ),
                      )
                    : _fileGlyph(tokens),
              ),
            ),
          ),
          if (attachment is UploadingAttachment)
            _scrim(
              tokens,
              child: const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          if (spoiler && attachment is UploadedAttachment)
            _scrim(
              tokens,
              child: Icon(
                AppIcons.spoiler,
                size: AppSizes.icon16,
                color: tokens.textPrimary,
              ),
            ),
          if (attachment is FailedAttachment)
            _scrim(
              tokens,
              child: Icon(
                AppIcons.failed,
                size: AppSizes.icon20,
                color: tokens.dangerText,
              ),
            ),
        ],
      ),
    );
  }

  Widget _fileGlyph(AppTokens tokens) => Center(
    child: Icon(
      AppIcons.attachFile,
      size: AppSizes.icon16,
      color: tokens.textSecondary,
    ),
  );

  Widget _scrim(AppTokens tokens, {required Widget child}) => Positioned.fill(
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceBase.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Center(child: child),
    ),
  );
}

/// A small icon-only control on a tile: remove always, retry once failed.
///
/// Stateful for one reason: it lights a hover background so the target reads
/// as tappable before it is clicked (it had a bare cursor-less GestureDetector
/// before, which the owner reported as not looking noticeable), and it fires a
/// selection haptic on tap so a touch device confirms the removal.
class _TileButton extends StatefulWidget {
  const _TileButton({
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
    this.tooltip,
    this.active = false,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback onTap;
  final String? tooltip;

  /// On, for a toggle: drawn in the accent, the viewer's own choice.
  final bool active;

  @override
  State<_TileButton> createState() => _TileButtonState();
}

class _TileButtonState extends State<_TileButton> {
  bool _hovered = false;

  void _handleTap() {
    HapticFeedback.selectionClick();
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final button = Semantics(
      button: true,
      toggled: widget.tooltip == null ? null : widget.active,
      label: widget.semanticLabel,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: _handleTap,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: _hovered ? tokens.surfaceSunken : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            child: Icon(
              widget.icon,
              size: AppSizes.icon16,
              color: widget.active
                  ? tokens.accent
                  : _hovered
                  ? tokens.textPrimary
                  : tokens.textSecondary,
            ),
          ),
        ),
      ),
    );
    final tooltip = widget.tooltip;
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}
