// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What rebuilds while someone talks: the SFU re-reports a talker's level
/// about twice a second and the roster flips `isSpeaking` on every pause, so the
/// header, the strip and the stage each have to rebuild only for what they draw.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/call_header_fixture.dart';

VoiceParticipant _who(
  String id, {
  bool speaking = false,
  double level = 0,
  bool muted = false,
}) => VoiceParticipant(
  identity: id,
  name: id,
  isLocal: id == 'me',
  isSpeaking: speaking,
  isMuted: muted,
  isScreenSharing: false,
  audioLevel: level,
);

final _members = [
  callProfile('me', 'Me'),
  callProfile('alice', 'Alice'),
  callProfile('bob', 'Bob'),
  callProfile('cy', 'Cy'),
];

Future<CallFixture> _joined(
  WidgetTester tester,
  List<VoiceParticipant> roster,
) async {
  final call = await joinCall(
    tester,
    width: 1400,
    members: _members,
    online: <String>{},
    withStrip: true,
  );
  await call.emit(roster);
  return call;
}

/// Runs [changes] one frame apart and counts how often each widget type rebuilt.
Future<Map<String, int>> _rebuilds(
  WidgetTester tester,
  CallFixture call,
  List<List<VoiceParticipant>> changes,
) async {
  final rebuilt = <String, int>{};
  debugOnRebuildDirtyWidget = (element, _) {
    final name = element.widget.runtimeType.toString();
    rebuilt[name] = (rebuilt[name] ?? 0) + 1;
  };
  addTearDown(() => debugOnRebuildDirtyWidget = null);
  for (final roster in changes) {
    call.session.emitParticipants(roster);
    await tester.pump(const Duration(milliseconds: 16));
  }
  debugOnRebuildDirtyWidget = null;
  return rebuilt;
}

void main() {
  testWidgets('a level tick under a steady talker rebuilds nothing', (
    tester,
  ) async {
    final call = await _joined(tester, [
      _who('me'),
      _who('alice'),
      _who('bob'),
      _who('cy'),
    ]);
    // Not call.emit: a lit ring pulses for good, so the tree never settles.
    call.session.emitParticipants([
      _who('me'),
      _who('alice', speaking: true, level: 0.2),
      _who('bob'),
      _who('cy'),
    ]);
    await tester.pump(const Duration(milliseconds: 16));

    final rebuilt = await _rebuilds(tester, call, [
      for (final level in [0.31, 0.47, 0.22, 0.58])
        [
          _who('me'),
          _who('alice', speaking: true, level: level),
          _who('bob'),
          _who('cy'),
        ],
    ]);

    expect(rebuilt['CallStageLayout'], isNull);
    expect(rebuilt['CallHeaderLine'], isNull);
    expect(rebuilt['VoiceStripIndicator'], isNull);
    expect(rebuilt['CallParticipantTile'], isNull);
    await call.leave();
  });

  testWidgets('a speaking flip leaves the header alone', (tester) async {
    final call = await _joined(tester, [
      _who('me'),
      _who('alice'),
      _who('bob'),
      _who('cy'),
    ]);

    final rebuilt = await _rebuilds(tester, call, [
      for (var i = 0; i < 4; i++)
        [
          _who('me'),
          _who('alice'),
          _who('bob', speaking: i.isEven),
          _who('cy'),
        ],
    ]);

    expect(rebuilt['CallHeaderLine'], isNull);
    expect(rebuilt['CallStageLayout'], isNull);
    expect(rebuilt['PoorConnectionBanner'], isNull);
    await call.leave();
  });

  testWidgets('the strip rebuilds for the two faces it draws, not the rest', (
    tester,
  ) async {
    final call = await _joined(tester, [
      _who('me'),
      _who('alice'),
      _who('bob'),
      _who('cy'),
    ]);

    final offscreen = await _rebuilds(tester, call, [
      for (var i = 0; i < 4; i++)
        [
          _who('me'),
          _who('alice'),
          _who('bob'),
          _who('cy', speaking: i.isEven),
        ],
    ]);
    final shown = await _rebuilds(tester, call, [
      for (var i = 0; i < 4; i++)
        [
          _who('me'),
          _who('alice', speaking: i.isEven),
          _who('bob'),
          _who('cy'),
        ],
    ]);

    expect(offscreen['_Summary'], isNull);
    expect(shown['_Summary'], greaterThan(0));
    await call.leave();
  });

  testWidgets('the header follows the head count', (tester) async {
    final call = await _joined(tester, [_who('me'), _who('alice')]);
    expect(find.text('2 in call'), findsOneWidget);

    await call.emit([_who('me'), _who('alice'), _who('bob')]);

    expect(find.text('3 in call'), findsOneWidget);
    await call.leave();
  });
}
