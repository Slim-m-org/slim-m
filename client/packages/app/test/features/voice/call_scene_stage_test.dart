// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module's call scene on the call's stage (decision 0132): the scene the
/// module drew from its room state takes the place a share would, a tap on it
/// is the room's next input, another player's move repaints it, and a refused
/// move says why under the board. Checked at phone and desktop width.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_stage_layout.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _title = 'Noughts and crosses';
const _grid = 'Scene grid. Arrow keys move, enter or space selects.';

const _me = VoiceParticipant(
  identity: 'user-1',
  name: 'Bob',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);

const _alice = VoiceParticipant(
  identity: 'user-2',
  name: 'Alice',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

/// A three by three board whose every cell sends `cell:<row>,<col>`.
Map<String, Object?> _scene(String board, String status) => {
  r'$slim': 'scene/1',
  'width': 90,
  'height': 90,
  'ops': [
    {
      'op': 'cells',
      'cols': 3,
      'rows': 3,
      'data': board,
      'palette': ['sunken', 'accent', 'text'],
      'gap': 2,
      'tap': 'cell',
    },
  ],
  'status': status,
  'controls': ['new game'],
};

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// The server: one game in progress, and an answer for each input sent.
class _Server {
  final inputs = <String>[];

  http.Client client() {
    final voice = voiceApi();
    return MockClient((request) async {
      final path = request.url.path;
      if (path == '/channels/channel-1/module-rooms') {
        return _json({
          'rooms': [
            {
              'module_id': 'noughts',
              'seq': 1,
              'state': {'board': '0........'},
              'scene': _scene('100000000', 'O to move'),
              'updated_at_ms': 1,
            },
          ],
          'call_scenes': [
            {'module_id': 'noughts', 'name': 'board', 'title': _title},
          ],
        });
      }
      if (path == '/channels/channel-1/module-rooms/noughts/inputs') {
        final input = (jsonDecode(request.body) as Map)['input'] as String;
        inputs.add(input);
        if (input == 'cell:0,0') {
          return _json({
            'applied': false,
            'seq': 1,
            'state': {'board': '0........'},
            'reason': 'that cell is taken',
          });
        }
        return _json({
          'applied': true,
          'seq': 2,
          'state': {'board': '0...o....'},
          'scene': _scene('100020000', 'X to move'),
        });
      }
      return voice.send(request).then(http.Response.fromStream);
    });
  }
}

class _Rig {
  _Rig(this.tester, this.server, this.events);

  final WidgetTester tester;
  final _Server server;
  final StreamController<api.ServerEvent> events;

  Rect get card =>
      tester.getRect(find.bySemanticsLabel(RegExp('^$_title')).first);
  Rect get board => tester.getRect(find.bySemanticsLabel(_grid));
  Rect get alice => tester.getRect(find.bySemanticsLabel(RegExp('^Alice')));

  /// Taps the centre of the board's cell at [row], [col].
  Future<void> tapCell(int row, int col) async {
    final b = board;
    await tester.tapAt(
      Offset(
        b.left + b.width * (col + 0.5) / 3,
        b.top + b.height * (row + 0.5) / 3,
      ),
    );
    await _settle(tester);
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _inCall(
  WidgetTester tester,
  Size size,
  Future<void> Function(_Rig rig) body,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final handle = tester.ensureSemantics();
  final server = _Server();
  final events = StreamController<api.ServerEvent>.broadcast();
  final harness = VoiceHarness();
  final session = FakeSession();
  final VoiceController controller = harness.controllerWith(
    session,
    server.client(),
    extraOverrides: [liveEventsProvider.overrideWithValue(events.stream)],
  );
  try {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: CallStageLayout(
              controller: controller,
              onOpenProfile: (_, _) {},
              isDm: false,
            ),
          ),
        ),
      ),
    );
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    session.emitParticipants(const [_me, _alice]);
    await _settle(tester);
    await body(_Rig(tester, server, events));
  } finally {
    await events.close();
    harness.dispose();
    handle.dispose();
  }
}

void _expectStageGeometry(_Rig rig, Size size) {
  final card = rig.card;
  final board = rig.board;
  expect(card.left, greaterThanOrEqualTo(0));
  expect(card.right, lessThanOrEqualTo(size.width));
  expect(
    card.overlaps(rig.alice),
    isFalse,
    reason: 'the scene must not cover a participant',
  );
  expect(board.width, closeTo(board.height, 1), reason: 'a square board');
  expect(
    card.contains(board.topLeft) &&
        card.contains(board.bottomRight - const Offset(1, 1)),
    isTrue,
  );
  expect(board.width, greaterThan(size.width < 600 ? 200 : 320));
}

void main() {
  for (final size in const [Size(390, 844), Size(1280, 800)]) {
    final wide = size.width.toInt();

    testWidgets('at $wide wide the game in progress takes the stage beside '
        'the participants, a tap is the next input and a refusal says why', (
      tester,
    ) async {
      await _inCall(tester, size, (rig) async {
        expect(find.text('O to move'), findsOneWidget);
        _expectStageGeometry(rig, size);

        await rig.tapCell(1, 1);
        expect(rig.server.inputs, ['cell:1,1']);
        expect(find.text('X to move'), findsOneWidget);

        await rig.tapCell(0, 0);
        expect(rig.server.inputs.last, 'cell:0,0');
        final reason = find.text('that cell is taken');
        expect(reason, findsOneWidget);
        expect(rig.card.contains(tester.getCenter(reason)), isTrue);
        expect(find.text('X to move'), findsOneWidget);

        await tester.tap(find.text('new game'));
        await _settle(tester);
        expect(rig.server.inputs.last, 'new game');
      });
    });

    testWidgets('at $wide wide another player\'s move repaints the scene, '
        'and an older frame does not', (tester) async {
      await _inCall(tester, size, (rig) async {
        rig.events.add(
          api.ModuleRoomChanged(
            channelId: 'channel-1',
            moduleId: 'noughts',
            seq: 3,
            state: const {'board': '0...o...0'},
            scene: jsonEncode(_scene('100020001', 'O to move, X threatens')),
          ),
        );
        await _settle(tester);
        expect(find.text('O to move, X threatens'), findsOneWidget);
        _expectStageGeometry(rig, size);

        rig.events.add(
          api.ModuleRoomChanged(
            channelId: 'channel-1',
            moduleId: 'noughts',
            seq: 2,
            state: const {'board': '0...o....'},
            scene: jsonEncode(_scene('100020000', 'stale')),
          ),
        );
        await _settle(tester);
        expect(find.text('stale'), findsNothing);
      });
    });
  }

  testWidgets('closing the scene leaves the stage to the call, and the '
      'header opens it again', (tester) async {
    await _inCall(tester, const Size(1280, 800), (rig) async {
      await tester.tap(find.bySemanticsLabel('Close $_title'));
      await _settle(tester);
      expect(find.bySemanticsLabel(RegExp('^$_title')), findsNothing);
      expect(rig.server.inputs, isEmpty);

      await tester.tap(find.bySemanticsLabel('Open $_title'));
      await _settle(tester);
      expect(find.text('O to move'), findsOneWidget);
      expect(rig.server.inputs, isEmpty, reason: 'a held room is not reopened');
    });
  });
}
