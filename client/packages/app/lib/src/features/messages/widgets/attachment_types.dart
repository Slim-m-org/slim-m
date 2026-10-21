// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which attachments render inline, and how large an inline image may be.
library;

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

/// Mirrors `media::is_inline` in `crates/slimm-server/src/media.rs`; an allowlist like the server's, so an unrecognised type falls back to the filename chip.
const Set<String> inlineImageTypes = {
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
};

bool isInlineImage(String contentType) =>
    inlineImageTypes.contains(contentType);

/// The images on a message in order, so opening one fullscreen pages to the rest; beside [isInlineImage] so gallery and thumbnail share one rule.
List<api.Attachment> openableImages(List<api.Attachment> attachments) =>
    attachments
        .where((a) => isInlineImage(a.contentType))
        .toList(growable: false);

/// A prefix match, unlike [inlineImageTypes]: the server serves every `video/*` as a download and `media_kit` tries whatever its backend supports.
/// A file it cannot decode fails through `Player.stream.error`.
bool isVideo(String contentType) => contentType.startsWith('video/');

/// The largest an image is drawn inline, in logical pixels, on both axes: half [kMessageColumnMax].
/// Uncapped, one image could fill a desktop screen; full size is one tap away.
const double kInlineImageMax = kMessageColumnMax / 2;
