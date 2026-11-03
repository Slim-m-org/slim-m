// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The republish rule: a steady poll hands back an equal value (so nothing is
/// sent), while a track change, a seek or a pause produces a different one.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/spotify/spotify_source.dart';
import 'package:slimm_platform/platform.dart';

final _t0 = DateTime.utc(2026, 11, 3, 12);
const _song = NowPlaying(title: 'Song', artist: 'A', source: 'Spotify');
const _other = NowPlaying(title: 'Other', artist: 'A', source: 'Spotify');

void main() {
  test('steady polls return the very same value', () {
    final anchor = ProgressAnchor();
    final first = anchor.apply(_song, 10000, 200000, _t0);
    final second = anchor.apply(
      _song,
      20400,
      200000,
      _t0.add(const Duration(seconds: 10)),
    );
    expect(second, first);
    expect(first.positionMs, 10000);
    expect(first.sampledAtMs, _t0.millisecondsSinceEpoch);
  });

  test('a seek past the tolerance produces a new anchor', () {
    final anchor = ProgressAnchor();
    final first = anchor.apply(_song, 10000, 200000, _t0);
    final after = anchor.apply(
      _song,
      90000,
      200000,
      _t0.add(const Duration(seconds: 10)),
    );
    expect(after, isNot(first));
    expect(after.positionMs, 90000);
  });

  test('a track change, and a pause then resume, produce a new anchor', () {
    final anchor = ProgressAnchor();
    final first = anchor.apply(_song, 10000, 200000, _t0);
    expect(anchor.apply(_other, 10000, 200000, _t0), isNot(first));
    anchor.reset();
    final resumed = anchor.apply(
      _song,
      10000,
      200000,
      _t0.add(const Duration(seconds: 30)),
    );
    expect(resumed, isNot(first));
  });

  test('a track with no length carries no progress', () {
    final plain = ProgressAnchor().apply(_song, 5, null, _t0);
    expect(plain.positionMs, isNull);
    expect(plain, _song);
  });
}
