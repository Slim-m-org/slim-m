// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The client's copy of the server's hidden-character rule, and the cleaning
/// built on it. The server refuses activity text, names and labels holding one
/// rather than trimming them, so text sent to it has to be cleaned first.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/hidden_characters.dart';
import 'package:slimm_app/src/providers/activity_feeds.dart';
import 'package:slimm_platform/platform.dart';

Directory _repoRoot() {
  var dir = Directory.current.absolute;
  while (!File('${dir.path}/schema/openapi.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('repo root not found');
    dir = parent;
  }
  return dir;
}

int _hex(Object? value) => int.parse(value! as String, radix: 16);

void main() {
  group('isHiddenCharacter', () {
    final fixture =
        jsonDecode(
              File(
                '${_repoRoot().path}/crates/slimm-server/tests/fixtures/hidden_chars.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final ranges = [
      for (final r in (fixture['hidden'] as List).cast<Map<String, dynamic>>())
        (_hex(r['from']), _hex(r['to'])),
    ];

    test('every code point agrees with the shared fixture, tab included', () {
      final wrong = <String>[];
      for (var c = 0; c <= 0x10FFFF; c++) {
        if (c >= 0xD800 && c <= 0xDFFF) continue;
        final expected = ranges.any((r) => c >= r.$1 && c <= r.$2);
        if (isHiddenCharacter(c) != expected) {
          wrong.add('U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}');
        }
      }
      expect(wrong, isEmpty, reason: 'disagree with hidden_chars.json');
    });
  });

  group('visibleText', () {
    test('drops a zero width character without leaving a gap', () {
      expect(visibleText('a​b'), 'ab');
    });

    test('keeps a break between words as one space', () {
      expect(visibleText('one\ntwo\t\tthree'), 'one two three');
    });

    test('drops direction marks and the braille blank', () {
      expect(visibleText('a\u202eb⠀c'), 'abc');
    });

    test('trims the ends and leaves ordinary text alone', () {
      expect(visibleText('  Café ❤️  '), 'Café ❤️');
    });

    test('leaves nothing of text that was only hidden characters', () {
      expect(visibleText('​ㅤ⠀'), isEmpty);
    });
  });

  group('what a track shares', () {
    test('a title with a hidden character is cleaned', () {
      final activity = activityFromNowPlaying(
        const NowPlaying(title: 'a​b', artist: 'x\u202ey'),
      );

      expect(activity?.title, 'ab');
      expect(activity?.subtitle, 'xy');
    });

    test('a title with nothing visible shares nothing', () {
      expect(activityFromNowPlaying(const NowPlaying(title: '​⠀')), isNull);
    });

    test('an artist with nothing visible is left off', () {
      final activity = activityFromNowPlaying(
        const NowPlaying(title: 'Song', artist: '​'),
      );

      expect(activity?.subtitle, isNull);
    });

    test('a blank source is left off, never sent blank', () {
      final activity = activityFromNowPlaying(
        const NowPlaying(title: 'Song', source: '  ​ '),
      );

      expect(activity?.source, isNull);
    });

    test('a game with nothing visible in its name shares nothing', () {
      expect(activityFromGame(const RunningGame('​')), isNull);
    });
  });
}
