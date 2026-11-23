// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// App state a search entry can depend on, so settings search never offers a
/// row the pane is not rendering.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../spotify/spotify_config.dart';
import '../../../spotify/spotify_link.dart';
import '../../../spotify/spotify_link_status.dart';
import '../../voice/providers/call_stats.dart';
import 'linked_accounts.dart';
import 'settings_index.dart';
import 'stored_theme.dart';

enum SettingsGate {
  spotifyConfigured,
  spotifyLinked,
  steamLinked,
  spaceDefaultTheme,

  /// The Space transcribes calls, so there are stats to show.
  callTranscripts,
}

bool _open(Ref ref, SettingsGate gate) => switch (gate) {
  SettingsGate.spotifyConfigured => _spotifyConfigured(ref),
  SettingsGate.spotifyLinked =>
    _spotifyConfigured(ref) &&
        ref.watch(spotifyLinkStatusProvider) is SpotifyConnected,
  SettingsGate.steamLinked =>
    ref.watch(myLinkedAccountsProvider).valueOrNull?.any((l) => l.isSteam) ??
        false,
  SettingsGate.spaceDefaultTheme =>
    ref.watch(spaceDefaultThemeProvider) != null,
  SettingsGate.callTranscripts => ref.watch(callStatsAvailableProvider),
};

bool _spotifyConfigured(Ref ref) =>
    ref.watch(spotifyClientIdProvider.select((id) => id.isNotEmpty));

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
