// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [activeShares] ordering and focus, and the stop-watching state that ends
/// with the share it was chosen for.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/call_mini_player.dart';
import 'package:slimm_app/src/features/voice/providers/share_watch.dart';
import 'package:slimm_rtc/rtc.dart';

VoiceParticipant _p(String id, {bool local = false, bool sharing = true}) =>
    VoiceParticipant(
      identity: id,
      name: id,
      isLocal: local,
      isSpeaking: false,
      isMuted: false,
      isScreenSharing: sharing,
    );

List<String> _ids(List<VoiceParticipant> l) => [for (final p in l) p.identity];

void main() {
  final roster = [
    _p('me', local: true),
    _p('a'),
    _p('idle', sharing: false),
    _p('b'),
  ];

  test('remote sharers in roster order, then local', () {
    expect(_ids(activeShares(roster)), ['a', 'b', 'me']);
  });

  test('a focused sharer comes first, the rest keep their order', () {
    expect(_ids(activeShares(roster, focusedIdentity: 'b')), ['b', 'a', 'me']);
    expect(_ids(activeShares(roster, focusedIdentity: 'me')), ['me', 'a', 'b']);
  });

  test('a focus on someone not sharing changes nothing', () {
    expect(_ids(activeShares(roster, focusedIdentity: 'idle')), [
      'a',
      'b',
      'me',
    ]);
  });

  test('stopped sharers drop out of the stage', () {
    expect(_ids(activeShares(roster, stopped: {'a'})), ['b', 'me']);
  });

  test('stop and watch report the blocked share keys', () {
    final applied = <Set<String>>[];
    final c = ShareWatchController(applied.add);
    c.stop('a');
    expect(c.state.stopped, {'a'});
    expect(applied.last, {'screen:a'});
    c.watch('a');
    expect(c.state.stopped, isEmpty);
    expect(applied.last, isEmpty);
  });

  test('stopping the focused share clears the focus', () {
    final c = ShareWatchController((_) {});
    c.focus('a');
    c.stop('a');
    expect(c.state.focused, isNull);
  });

  test('a share that ends is forgotten, so its next share shows again', () {
    final applied = <Set<String>>[];
    final c = ShareWatchController(applied.add);
    c.stop('a');
    c.focus('b');
    c.prune({'b'});
    expect(c.state.stopped, isEmpty);
    expect(c.state.focused, 'b');
    expect(applied.last, isEmpty);
    c.prune({});
    expect(c.state.focused, isNull);
  });

  test('the mini player skips a stopped share for the next feed', () {
    final people = [_p('a'), _p('b')];
    expect(pickMiniPlayerFeed(people)!.identity, 'a');
    expect(pickMiniPlayerFeed(people, stoppedShares: {'a'})!.identity, 'b');
    expect(pickMiniPlayerFeed(people, stoppedShares: {'a', 'b'}), isNull);
  });
}
