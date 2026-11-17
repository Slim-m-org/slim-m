// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The result of `SlimmApiLinkPreview.fetchLinkPreview`.
library;

/// A recognized playable media provider a link preview can carry. Unknown
/// values from a future server decode to null on this client rather than
/// throwing, the same forward-compatibility [LinkPreview.fromJson] already
/// gives every other field.
enum LinkPreviewVideoProvider {
  youtube,
  spotify;

  static LinkPreviewVideoProvider? fromWire(String? value) => switch (value) {
        'youtube' => youtube,
        'spotify' => spotify,
        _ => null,
      };
}

/// What a Spotify id names; [name] is both the wire value and the URL segment.
enum SpotifyKind {
  track,
  album,
  playlist,
  artist,
  show,
  episode;

  static SpotifyKind? fromWire(String? value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

/// One Spotify item. Every link to it is built here from [kind] and [id],
/// never from a URL the server forwarded.
class SpotifyEntity {
  const SpotifyEntity._(this.kind, this.id);

  /// Null unless [id] is a real Spotify id, so no URL is ever built around
  /// anything else.
  static SpotifyEntity? tryCreate(SpotifyKind? kind, String? id) {
    if (kind == null || id == null || !_id.hasMatch(id)) return null;
    return SpotifyEntity._(kind, id);
  }

  static final _id = RegExp(r'^[0-9A-Za-z]{22}$');

  final SpotifyKind kind;
  final String id;

  Uri get webUrl => Uri.https('open.spotify.com', '/${kind.name}/$id');

  /// `spotify:track:<id>`, which the Spotify desktop app registers.
  Uri get appUri => Uri(scheme: 'spotify', path: '${kind.name}:$id');

  Uri get embedUrl => Uri.https('open.spotify.com', '/embed/${kind.name}/$id');

  /// Spotify's own oEmbed heights: the compact player for a single track or
  /// episode, the list player for everything else.
  double get embedHeight => switch (kind) {
        SpotifyKind.track || SpotifyKind.episode => 152,
        _ => 352,
      };

  @override
  bool operator ==(Object other) =>
      other is SpotifyEntity && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// A pasted URL's unfurled OpenGraph/title metadata. [imageToken] is an
/// opaque token minted by the server, redeemable at `fetchLinkPreviewImage`
/// - never the upstream image URL, so nothing about displaying a preview
/// ever reaches the linked site directly.
///
/// [videoProvider]/[videoId] are set together when the server recognized the
/// linked page as playable media (a YouTube video or a Spotify item): a
/// caller renders a click-to-play affordance instead of the static card, and
/// must not contact the provider until the reader taps - see
/// `link_preview_card.dart`.
///
/// [authorName]/[authorUrl] are the page's author or publisher, if known - a
/// recognized video's channel today. A Spotify item is [spotify] instead.
class LinkPreview {
  const LinkPreview({
    required this.url,
    this.title,
    this.description,
    this.siteName,
    this.imageToken,
    this.videoProvider,
    this.videoId,
    this.mediaKind,
    this.durationMs,
    this.authorName,
    this.authorUrl,
  });

  /// The URL this preview is for, echoed back so a caller can key its own
  /// cache.
  final String url;

  /// The page's OpenGraph or plain title, if any.
  final String? title;

  /// The page's OpenGraph or meta description, if any.
  final String? description;

  /// The page's OpenGraph site name, if any.
  final String? siteName;

  /// An opaque token for the preview image, redeemable at
  /// `fetchLinkPreviewImage`. Null when the page had no usable image.
  final String? imageToken;

  /// Which known provider the linked page's video is, if any. Null for an
  /// ordinary link.
  final LinkPreviewVideoProvider? videoProvider;

  /// The provider's own canonical video id, paired with [videoProvider] -
  /// never a URL, so a caller builds its own playback URL from the two.
  final String? videoId;

  /// The page's author or publisher, if known - a recognized video's channel
  /// name today. Null for an ordinary link, or when the server's oembed
  /// request for it failed.
  final String? authorName;

  /// The author's own page, paired with [authorName] - a channel name a
  /// reader cannot click is less useful. Null unless [authorName] is set.
  final String? authorUrl;

  /// What a Spotify [videoId] names; null for anything else.
  final SpotifyKind? mediaKind;

  /// The track's or episode's length, when its page declared one.
  final int? durationMs;

  /// Whether this preview is a YouTube video that renders click-to-play over
  /// its thumbnail. A Spotify item is never this, since nothing may be drawn
  /// over its artwork; see [spotify].
  bool get isPlayableVideo =>
      videoProvider == LinkPreviewVideoProvider.youtube && videoId != null;

  /// The Spotify item this preview is for, or null.
  SpotifyEntity? get spotify =>
      videoProvider == LinkPreviewVideoProvider.spotify
          ? SpotifyEntity.tryCreate(mediaKind, videoId)
          : null;

  factory LinkPreview.fromJson(Map<String, dynamic> json) => LinkPreview(
        url: json['url'] as String,
        title: json['title'] as String?,
        description: json['description'] as String?,
        siteName: json['site_name'] as String?,
        imageToken: json['image_token'] as String?,
        videoProvider: LinkPreviewVideoProvider.fromWire(
          json['video_provider'] as String?,
        ),
        videoId: json['video_id'] as String?,
        mediaKind: SpotifyKind.fromWire(json['media_kind'] as String?),
        durationMs: (json['duration_ms'] as num?)?.toInt(),
        authorName: json['author_name'] as String?,
        authorUrl: json['author_url'] as String?,
      );

  /// The `youtube-nocookie.com` embed URL for inline web playback - no
  /// cookies set until the reader taps and this actually loads. Null unless
  /// [isPlayableVideo]. Desktop and mobile do not use this: they open [url]
  /// (the pasted link itself) in the system browser instead, since Flutter
  /// has no iframe host off the web engine.
  Uri? get embedUrl {
    final id = videoId;
    if (videoProvider != LinkPreviewVideoProvider.youtube || id == null) {
      return null;
    }
    return Uri.https('www.youtube-nocookie.com', '/embed/$id', {
      'autoplay': '1',
    });
  }
}
