// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// App state a search entry can depend on, so settings search never offers a
/// row the pane is not rendering.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../spotify/spotify_config.dart';
import '../../../spotify/spotify_link.dart';
import '../../../spotify/spotify_link_status.dart';
import 'settings_index.dart';

enum SettingsGate { spotifyConfigured, spotifyLinked }

bool _open(Ref ref, SettingsGate gate) {
  final configured = ref.watch(
    spotifyClientIdProvider.select((id) => id.isNotEmpty),
  );
  return switch (gate) {
    SettingsGate.spotifyConfigured => configured,
    SettingsGate.spotifyLinked =>
      configured && ref.watch(spotifyLinkStatusProvider) is SpotifyConnected,
  };
}

/// [personalSettingsIndex] minus what this build and account cannot show.
final personalSearchEntriesProvider = Provider<List<SettingsEntry>>((ref) {
  final entries = <SettingsEntry>[];
  for (final entry in personalSettingsIndex) {
    final gate = entry.gate;
    if (gate != null && !_open(ref, gate)) continue;
    final keywordGate = entry.keywordGate;
    final extra = keywordGate == null || _open(ref, keywordGate);
    entries.add(extra ? entry.withKeywords(entry.gatedKeywords) : entry);
  }
  return entries;
});
