// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('LinkPreview.fromJson reads every field', () {
    final preview = LinkPreview.fromJson({
      'url': 'https://example.com/article',
      'title': 'An article',
      'description': 'What the article is about.',
      'site_name': 'Example',
      'image_token': 'a-token',
    });
    expect(preview.url, 'https://example.com/article');
    expect(preview.title, 'An article');
    expect(preview.description, 'What the article is about.');
    expect(preview.siteName, 'Example');
    expect(preview.imageToken, 'a-token');
  });

  test('a page with no usable metadata reads every optional field as null', () {
    final preview = LinkPreview.fromJson({'url': 'https://example.com'});
    expect(preview.url, 'https://example.com');
    expect(preview.title, isNull);
    expect(preview.description, isNull);
    expect(preview.siteName, isNull);
    expect(preview.imageToken, isNull);
    expect(preview.videoProvider, isNull);
    expect(preview.videoId, isNull);
    expect(preview.authorName, isNull);
    expect(preview.authorUrl, isNull);
    expect(preview.isPlayableVideo, isFalse);
  });

  test('a recognized video reads its channel name and url', () {
    final preview = LinkPreview.fromJson({
      'url': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      'video_provider': 'youtube',
      'video_id': 'dQw4w9WgXcQ',
      'author_name': 'A Channel',
      'author_url': 'https://www.youtube.com/@achannel',
    });
    expect(preview.authorName, 'A Channel');
    expect(preview.authorUrl, 'https://www.youtube.com/@achannel');
  });

  test('a recognized YouTube video reads as playable', () {
    final preview = LinkPreview.fromJson({
      'url': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      'video_provider': 'youtube',
      'video_id': 'dQw4w9WgXcQ',
    });
    expect(preview.videoProvider, LinkPreviewVideoProvider.youtube);
    expect(preview.videoId, 'dQw4w9WgXcQ');
    expect(preview.isPlayableVideo, isTrue);
  });

  test('an unknown future provider decodes to null rather than throwing', () {
    final preview = LinkPreview.fromJson({
      'url': 'https://example.com/video',
      'video_provider': 'vimeo',
      'video_id': '12345',
    });
    expect(preview.videoProvider, isNull);
    expect(preview.isPlayableVideo, isFalse);
  });

  test('embedUrl builds a youtube-nocookie autoplay URL', () {
    final preview = LinkPreview.fromJson({
      'url': 'https://youtu.be/dQw4w9WgXcQ',
      'video_provider': 'youtube',
      'video_id': 'dQw4w9WgXcQ',
    });
    expect(
      preview.embedUrl.toString(),
      'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?autoplay=1',
    );
  });

  test('a link start time reads as videoStart and reaches the embed URL', () {
    final preview = LinkPreview.fromJson({
      'url': 'https://youtu.be/dQw4w9WgXcQ?t=90',
      'video_provider': 'youtube',
      'video_id': 'dQw4w9WgXcQ',
      'video_start_ms': 90000,
    });
    expect(preview.videoStart, const Duration(seconds: 90));
    expect(
      preview.embedUrl.toString(),
      'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?autoplay=1&start=90',
    );
  });

  test('an older server with no start reads videoStart as zero', () {
    final preview = LinkPreview.fromJson({
      'url': 'https://youtu.be/dQw4w9WgXcQ',
      'video_provider': 'youtube',
      'video_id': 'dQw4w9WgXcQ',
    });
    expect(preview.videoStartMs, isNull);
    expect(preview.videoStart, Duration.zero);
  });

  test('embedUrl is null for a non-video preview', () {
    final preview = LinkPreview.fromJson({'url': 'https://example.com'});
    expect(preview.embedUrl, isNull);
  });

  group('a Spotify item', () {
    const id = '3ccGTp44b5m3TwTCrolFjw';

    LinkPreview spotify(Map<String, Object?> extra) => LinkPreview.fromJson({
          'url': 'https://open.spotify.com/track/$id?si=x',
          'title': 'Some Men Drown',
          'site_name': 'Spotify',
          'video_provider': 'spotify',
          'video_id': id,
          'media_kind': 'track',
          'duration_ms': 336000,
          ...extra,
        });

    test('reads its kind, id and duration, and is not a YouTube video', () {
      final preview = spotify({});
      expect(preview.videoProvider, LinkPreviewVideoProvider.spotify);
      expect(preview.mediaKind, SpotifyKind.track);
      expect(preview.durationMs, 336000);
      expect(preview.isPlayableVideo, isFalse);
      expect(preview.embedUrl, isNull);
      expect(preview.spotify, SpotifyEntity.tryCreate(SpotifyKind.track, id));
    });

    test('builds its own links from kind and id', () {
      final item = spotify({'media_kind': 'album'}).spotify!;
      expect(item.webUrl.toString(), 'https://open.spotify.com/album/$id');
      expect(item.appUri.toString(), 'spotify:album:$id');
      expect(
        item.embedUrl.toString(),
        'https://open.spotify.com/embed/album/$id',
      );
    });

    test('uses the compact player only for a track or an episode', () {
      for (final kind in SpotifyKind.values) {
        final item = SpotifyEntity.tryCreate(kind, id)!;
        final compact =
            kind == SpotifyKind.track || kind == SpotifyKind.episode;
        expect(item.embedHeight, compact ? 152 : 352, reason: kind.name);
      }
    });

    test('every wire kind decodes and an unknown one is null', () {
      for (final kind in SpotifyKind.values) {
        expect(SpotifyKind.fromWire(kind.name), kind);
      }
      expect(SpotifyKind.fromWire('audiobook'), isNull);
      expect(SpotifyKind.fromWire(null), isNull);
    });

    test('a bad id, a missing kind or another provider is no Spotify item', () {
      for (final bad in [
        '3ccGTp44b5m3TwTCrolFj',
        '3ccGTp44b5m3TwTCrolFjwX',
        '3ccGTp44b5m3TwTCrolF/w',
        '../../../../../../etc/x',
      ]) {
        expect(spotify({'video_id': bad}).spotify, isNull, reason: bad);
      }
      expect(spotify({'media_kind': null}).spotify, isNull);
      expect(spotify({'media_kind': 'audiobook'}).spotify, isNull);
      expect(spotify({'video_provider': 'youtube'}).spotify, isNull);
    });

    test('an older server with no media fields reads them as null', () {
      final preview = LinkPreview.fromJson({'url': 'https://example.com'});
      expect(preview.mediaKind, isNull);
      expect(preview.durationMs, isNull);
      expect(preview.spotify, isNull);
    });
  });
}
