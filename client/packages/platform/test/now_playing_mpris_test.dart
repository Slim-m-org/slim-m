// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Choosing the track out of what MPRIS players report.
library;

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/src/now_playing_mpris.dart';

MprisPlayerState _player(
  String status, {
  String? title,
  List<String> artists = const [],
  String? identity,
  String? art,
}) =>
    MprisPlayerState(
      status: status,
      identity: identity,
      metadata: {
        if (title != null) 'xesam:title': DBusString(title),
        'xesam:artist': DBusArray.string(artists),
        if (art != null) 'mpris:artUrl': DBusString(art),
      },
    );

void main() {
  test('reports the playing track with its artists joined', () {
    final picked = pickNowPlaying([
      _player('Playing', title: 'Song', artists: ['A', 'B']),
    ]);
    expect(picked?.title, 'Song');
    expect(picked?.artist, 'A, B');
  });

  test('a paused or stopped player reports nothing', () {
    expect(pickNowPlaying([_player('Paused', title: 'Song')]), isNull);
    expect(pickNowPlaying([_player('Stopped', title: 'Song')]), isNull);
  });

  test('skips a playing player with no title and takes the next', () {
    final picked = pickNowPlaying([
      _player('Playing'),
      _player('Playing', title: 'Second'),
    ]);
    expect(picked?.title, 'Second');
    expect(picked?.artist, isNull);
  });

  test('no players means nothing playing', () {
    expect(pickNowPlaying(const []), isNull);
  });

  test('names the player so a browser tab is not read as Spotify', () {
    final picked = pickNowPlaying([
      _player('Playing', title: 'Video', identity: ' Mozilla Firefox '),
    ]);
    expect(picked?.source, 'Mozilla Firefox');
    expect(pickNowPlaying([_player('Playing', title: 'x')])?.source, isNull);
  });

  test('keeps cover art, and maps the open.spotify.com host to the CDN', () {
    const id = 'ab67616d0000b273bc2dd68b840b1d4b7c9e5ad9';
    expect(
      pickNowPlaying([
        _player('Playing', title: 'S', art: 'https://i.scdn.co/image/$id'),
      ])?.artUrl,
      'https://i.scdn.co/image/$id',
    );
    expect(
      pickNowPlaying([
        _player('Playing',
            title: 'S', art: 'https://open.spotify.com/image/$id'),
      ])?.artUrl,
      'https://i.scdn.co/image/$id',
    );
  });

  test('one player that breaks the spec does not hide the others', () {
    final broken = const MprisPlayerState(
      status: 'Playing',
      metadata: {
        'xesam:title': DBusString('Odd'),
        'xesam:artist': DBusString('not an array'),
      },
    );
    final picked = pickNowPlaying([
      broken,
      _player('Playing', title: 'Good', artists: ['A']),
    ]);
    expect(picked?.title, 'Good');
  });
}
