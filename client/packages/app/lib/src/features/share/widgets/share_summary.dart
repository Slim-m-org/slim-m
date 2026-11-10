// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What is about to be shared, so the person can tell the right thing arrived
/// before choosing where it goes.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/attachment_format.dart';
import '../providers/incoming_share.dart';

/// How many photo thumbnails the summary draws before the rest are only counted.
const _maxThumbnails = 3;

/// "3 photos", "report.pdf and text", "Text": the words for [share].
String shareSummaryTitle(IncomingShare share) {
  final files = share.files;
  final String? filesPart;
  if (files.isEmpty) {
    filesPart = null;
  } else if (files.length == 1) {
    filesPart = files.first.name;
  } else if (files.every((f) => f.isImage)) {
    filesPart = '${files.length} photos';
  } else if (files.every((f) => f.isVideo)) {
    filesPart = '${files.length} videos';
  } else {
    filesPart = '${files.length} files';
  }
  if (filesPart == null) return 'Text';
  return share.hasText ? '$filesPart and text' : filesPart;
}

/// The line under the title: the text's opening, else the combined size.
String? shareSummaryDetail(IncomingShare share) {
  final text = share.text?.trim();
  if (text != null && text.isNotEmpty) return text;
  if (share.files.isEmpty) return null;
  final total = share.files.fold<int>(0, (sum, f) => sum + f.length);
  return formatByteSize(total);
}

class ShareSummary extends StatelessWidget {
  const ShareSummary({super.key, required this.share});

  final IncomingShare share;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final detail = shareSummaryDetail(share);
    return MergeSemantics(
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s12),
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          border: Border.all(color: tokens.borderSubtle),
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        child: Row(
          children: [
            _Preview(share: share),
            const SizedBox(width: AppSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shareSummaryTitle(share),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.ui.copyWith(
                      color: tokens.textPrimary,
                      fontWeight: AppWeights.medium,
                    ),
                  ),
                  if (detail != null)
                    Text(
                      detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.share});

  final IncomingShare share;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final photos = [
      for (final file in share.files)
        if (file.isImage) file,
    ];
    if (photos.isEmpty) {
      return _Tile(
        child: Icon(
          share.hasFiles ? AppIcons.attachFile : AppIcons.chat,
          size: AppSizes.icon20,
          color: tokens.textSecondary,
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final photo in photos.take(_maxThumbnails))
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.s4),
            child: _Tile(
              child: Image.file(
                File(photo.path),
                width: _Tile.size,
                height: _Tile.size,
                fit: BoxFit.cover,
                cacheWidth: _Tile.size.toInt() * 2,
                excludeFromSemantics: true,
                errorBuilder: (context, _, _) => Icon(
                  AppIcons.imageMissing,
                  size: AppSizes.icon20,
                  color: tokens.textSecondary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.child});

  static const size = 44.0;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: child,
    );
  }
}
