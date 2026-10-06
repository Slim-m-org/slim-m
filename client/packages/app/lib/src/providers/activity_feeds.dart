// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rich-presence sources, all behind one seam (decision 0044).
///
/// A feed is a Settings switch plus a stream of what that source sees. The
/// publisher owns the privacy rules (switch on, not hidden, nothing opened
/// otherwise), so a new source only declares itself in [activityFeedsProvider]
/// and never touches them.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_platform/platform.dart';

import '../hidden_characters.dart';
import '../spotify/spotify_config.dart';
import '../spotify/spotify_link.dart';
import 'activity_sharing_settings.dart';

/// The platform's now-playing source, or null where there is none. Overridden
/// in tests with a fake.
final nowPlayingSourceProvider = Provider<NowPlayingSource?>(
  (ref) => createNowPlayingSource(),
);

/// A track as the wire carries it, cleaned and cut to what the server accepts:
/// it refuses hidden characters and blank text rather than trimming them, and a
/// refused activity is never going to be accepted on a retry. Null when nothing
/// shareable is left, which is a title with no visible text.
api.PresenceActivity? activityFromNowPlaying(NowPlaying playing) {
  final title = capActivityText(playing.title);
  if (title.isEmpty) return null;
  final artist = playing.artist == null ? '' : capActivityText(playing.artist!);
  final source = playing.source == null
      ? ''
      : String.fromCharCodes(
          visibleText(
            playing.source!,
          ).runes.take(api.PresenceActivity.maxSourceChars),
        );
  return api.PresenceActivity(
    kind: api.ActivityKind.listening,
    title: title,
    subtitle: artist.isEmpty ? null : artist,
    source: source.isEmpty ? null : source,
    artUrl: playing.artUrl,
  );
}

/// The platform's game source, or null where there is none. Overridden in
/// tests with a fake.
final gameSourceProvider = Provider<GameSource?>((ref) => createGameSource());

api.PresenceActivity? activityFromGame(RunningGame game) {
  final title = capActivityText(game.name);
  if (title.isEmpty) return null;
  return api.PresenceActivity(kind: api.ActivityKind.playing, title: title);
}

/// [text] with hidden characters removed, then cut to the server's cap.
String capActivityText(String text) => String.fromCharCodes(
  visibleText(text).runes.take(api.PresenceActivity.maxTextChars),
);

class ActivityFeed {
  const ActivityFeed({
    required this.label,
    required this.description,
    required this.enabled,
    required this.available,
    required this.open,
    required this.via,
  });

  /// The switch's label and the sentence saying what turning it on reads.
  final String label;
  final String description;

  /// The persisted switch; off until the person turns it on.
  final StateNotifierProvider<ActivitySwitchController, bool> enabled;

  /// Where the reading comes from, in a few words, so Settings can say which
  /// of two sources that both name a track is the one being shared.
  final String via;

  /// False where this device has no such source, so Settings omits the row.
  final ProviderListenable<bool> available;

  /// Starts reading. Called only while enabled and visible, and the returned
  /// stream is cancelled the moment either stops being true.
  final Stream<api.PresenceActivity?> Function(Ref ref) open;
}

final _listeningFeed = ActivityFeed(
  label: 'Show what I\'m listening to',
  description: 'Shows the track from any player on this computer.',
  enabled: shareListeningProvider,
  via: 'this device\'s media player',
  available: nowPlayingSourceProvider.select((source) => source != null),
  open: (ref) => ref
      .read(nowPlayingSourceProvider)!
      .watch()
      .map(
        (playing) => playing == null ? null : activityFromNowPlaying(playing),
      ),
);

final _gameFeed = ActivityFeed(
  label: 'Show my current game',
  description: 'Only games on the list below are ever shown.',
  enabled: shareGameProvider,
  via: 'the game list',
  available: gameSourceProvider.select((source) => source != null),
  open: (ref) => ref
      .read(gameSourceProvider)!
      .watch()
      .map((game) => game == null ? null : activityFromGame(game)),
);

final _spotifyFeed = ActivityFeed(
  label: 'Show my Spotify track',
  description: 'Shows your track even when you play on another device.',
  enabled: shareSpotifyProvider,
  via: 'your Spotify link',
  available: spotifyClientIdProvider.select((id) => id.isNotEmpty),
  open: (ref) => ref
      .read(spotifySourceProvider)
      .watch()
      .map(
        (playing) => playing == null ? null : activityFromNowPlaying(playing),
      ),
);

/// In priority order: when two sources both report something, the first
/// one is what others see.
final activityFeedsProvider = Provider<List<ActivityFeed>>(
  (ref) => [_listeningFeed, _spotifyFeed, _gameFeed],
);

/// Feeds this device can actually run, for Settings.
final availableActivityFeedsProvider = Provider<List<ActivityFeed>>((ref) {
  return [
    for (final feed in ref.watch(activityFeedsProvider))
      if (ref.watch(feed.available)) feed,
  ];
});

/// What the server last accepted as this device's activity, so Settings can
/// show exactly what others can read. Null when nothing is shared.
final sharedActivityProvider = StateProvider<api.PresenceActivity?>(
  (ref) => null,
);

/// The feed [sharedActivityProvider] came from, null when nothing is shared.
final sharedFeedProvider = StateProvider<ActivityFeed?>((ref) => null);
