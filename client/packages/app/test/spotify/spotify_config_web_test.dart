// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
@TestOn('browser')
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/spotify/spotify_config.dart';

void main() {
  test('a browser tab is never offered Spotify linking', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(spotifyClientIdProvider), isEmpty);
  });
}
