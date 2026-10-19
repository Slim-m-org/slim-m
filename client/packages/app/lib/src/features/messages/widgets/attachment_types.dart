// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which attachments render inline, and how large an inline image may be.
library;

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

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
