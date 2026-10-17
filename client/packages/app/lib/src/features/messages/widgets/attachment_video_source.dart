// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The seam between the inline video player and how each platform gets
/// authenticated attachment bytes to `package:media_kit`.
///
/// Attachment bytes are behind auth: the endpoint needs a bearer header, so a
/// bare URL cannot be handed to a player and trusted to work. Every native
/// platform `media_kit_video` wraps (mpv on Android/Linux/Windows,
/// `AVPlayer` on iOS/macOS) can attach a custom HTTP header to a network
/// source, so `attachment_video_source_io.dart` hands the player the
/// attachment endpoint directly with the header attached: real streaming,
/// range requests and all (`crates/slimm-server/src/http/attachment_range.rs`
/// already serves them), no upfront fetch.
///
/// The web backend cannot: it embeds a plain HTML `<video>` element, and a
/// browser gives that element no way to attach a header of its own (checked
/// against `media_kit`'s own web player source - it applies `httpHeaders`
/// only through its HLS.js path, never on a direct `element.src`
/// assignment). `attachment_video_source_web.dart` fetches the whole file
/// with the app's own bearer token instead, then hands the video element a
/// `blob:` URL, which needs no header at all - at the cost of buffering the
/// whole attachment before playback can start, unlike the native platforms.
library;

import 'package:media_kit/media_kit.dart';
import 'package:slimm_api/api.dart' as api;

abstract class AttachmentVideoSource {
  /// Resolves once playback can start, with the [Media] to open.
  ///
  /// [onProgress] reports a fetch fraction in `[0, 1]` when the platform must
  /// buffer the whole file first (web only), null when it is unknown or
  /// (native platforms) simply does not apply.
  Future<Media> open({
    required api.SlimmApi apiClient,
    required api.Attachment attachment,
    required void Function(double? progress) onProgress,
  });

  /// Whether the credentials [open] last used no longer match [apiClient]'s.
  bool isStale(api.SlimmApi apiClient);

  /// Releases anything [open] held onto: a blob URL, an in-flight request.
  void dispose();
}
