// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings search offers Spotify only where the Connections card shows it:
/// a build with a client id finds the Spotify row, and the show-track switch
/// only appears once linked.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/settings_index.dart';

import 'package:slimm_app/src/features/settings/providers/settings_index_gates.dart';
import 'package:slimm_app/src/spotify/spotify_link.dart';

import 'spotify/spotify_rig.dart';

List<String> _found(SpotifyRig rig, String query) => [
  for (final e in searchSettings(
    query,
    rig.container.read(personalSearchEntriesProvider),
  ))
    e.label,
];

void main() {
  test('a build without a Spotify client id never offers Spotify', () async {
    final rig = SpotifyRig(clientId: '');
    addTearDown(rig.dispose);
    await rig.start();
    expect(_found(rig, 'spotify'), isEmpty);
    expect(_found(rig, 'listening'), ["Show what I'm listening to"]);
  });

  test('configured but unlinked finds Connections and the link row', () async {
    final rig = SpotifyRig();
    addTearDown(rig.dispose);
    await rig.start();
    expect(_found(rig, 'spotify'), unorderedEquals(['Spotify', 'Connections']));
    expect(_found(rig, 'listening'), ["Show what I'm listening to"]);
  });

  test('linked adds the show-track switch', () async {
    final rig = SpotifyRig();
    addTearDown(rig.dispose);
    await rig.start();
    await rig.container.read(shareSpotifyProvider.notifier).connect();
    await rig.linker.handleCallback(rig.redirect());
    expect(
      _found(rig, 'spotify'),
      unorderedEquals(['Spotify', 'Show my Spotify track', 'Connections']),
    );
    expect(_found(rig, 'listening'), contains('Show my Spotify track'));
  });
}
