// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel settings' Canvas, Voice call and Discard hidden canvas rows: which channels show them, the optimistic save and its rollback, and the discard confirm.
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/channels/screens/channel_settings_screen.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import 'channel_management_harness.dart';

const _json = {'content-type': 'application/json'};

Finder _toggle(String label) =>
    find.byWidgetPredicate((w) => w is AppToggle && w.semanticLabel == label);

Finder _errorRow() => find.byWidgetPredicate((w) => w is AppErrorState);

class _Fixture {
  _Fixture(this.requests);

  final List<http.Request> requests;

  Iterable<Map<String, dynamic>> get patches => [
    for (final r in requests)
      if (r.method == 'PATCH') jsonDecode(r.body) as Map<String, dynamic>,
  ];
}

Future<_Fixture> _open(
  WidgetTester tester, {
  required Channel channel,
  bool canvasChannels = true,
  int permissions = Perm.manageChannels | Perm.manageCanvas,
  bool failPatch = false,
}) async {
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = _Fixture([]);
  await tester.pumpWidget(
    harness(
      SingleChildScrollView(
        child: ChannelSettingsPane(channel: channel, wasOpen: false),
      ),
      permissions: permissions,
      handler: (request) {
        fixture.requests.add(request);
        if (request.url.path == '/version') {
          return http.Response(
            jsonEncode({
              'name': 's',
              'version': '1',
              'protocol': 1,
              'canvas_channels': canvasChannels,
            }),
            200,
            headers: _json,
          );
        }
        if (request.method != 'PATCH') {
          return http.Response(
            request.url.path.contains('/voice') ? '{"participants": []}' : '{}',
            200,
          );
        }
        if (failPatch) {
          return http.Response(
            jsonEncode({'error': 'boom'}),
            500,
            headers: _json,
          );
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'id': channel.id,
            'name': channel.name,
            'kind': channel.kind,
            'created_at': 0,
            'canvas_enabled': body['canvas_enabled'] ?? channel.canvasEnabled,
            'voice_enabled': body['voice_enabled'] ?? channel.voiceEnabled,
          }),
          200,
          headers: _json,
        );
      },
    ),
  );
  await pumpFrames(tester, frames: 30);
  return fixture;
}

Channel _voice({bool? canvas, String? roomOwnerId}) => channel(
  'c1',
  'stage',
  kind: 'voice',
).copyWith(canvasEnabled: Value(canvas), roomOwnerId: Value(roomOwnerId));

Channel _canvas({bool? call}) =>
    channel('c1', 'board', kind: 'canvas').copyWith(voiceEnabled: Value(call));

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byWidgetPredicate((w) => w is ChannelSettingsPane)),
);

void main() {
  group('Canvas row', () {
    for (final (name, owner) in [
      ('a voice channel', null),
      ('a room', 'user-2'),
    ]) {
      testWidgets('$name offers it', (tester) async {
        await _open(tester, channel: _voice(canvas: true, roomOwnerId: owner));
        expect(find.text('Canvas'), findsOneWidget);
        expect(
          find.text(
            'A shared board for this call; turning it off only hides it.',
          ),
          findsOneWidget,
        );
        expect(find.text('Voice call'), findsNothing);
      });
    }

    testWidgets('a text channel does not', (tester) async {
      await _open(tester, channel: channel('c1', 'general'));
      expect(find.text('Canvas'), findsNothing);
      expect(find.text('Voice call'), findsNothing);
    });

    testWidgets('a DM does not', (tester) async {
      await _open(tester, channel: channel('c1', 'dm', kind: 'dm'));
      expect(find.text('Canvas'), findsNothing);
    });

    testWidgets('an older server hides it and the discard row', (tester) async {
      await _open(
        tester,
        channel: _voice(canvas: false),
        canvasChannels: false,
      );
      expect(find.text('Canvas'), findsNothing);
      expect(find.text('Discard canvas...'), findsNothing);
    });

    testWidgets('turning it off saves canvas_enabled false at once', (
      tester,
    ) async {
      final f = await _open(tester, channel: _voice(canvas: true));
      const label = 'Add a canvas to this channel';
      expect(tester.widget<AppToggle>(_toggle(label)).value, isTrue);

      await tester.tap(_toggle(label));
      await tester.pump();
      expect(tester.widget<AppToggle>(_toggle(label)).value, isFalse);
      await pumpFrames(tester, frames: 30);

      expect(f.patches, [
        {'canvas_enabled': false},
      ]);
      expect(tester.widget<AppToggle>(_toggle(label)).value, isFalse);
    });

    testWidgets('a failed save rolls back and says so on the row', (
      tester,
    ) async {
      await _open(tester, channel: _voice(canvas: true), failPatch: true);
      const label = 'Add a canvas to this channel';
      await tester.tap(_toggle(label));
      await pumpFrames(tester, frames: 30);

      expect(tester.widget<AppToggle>(_toggle(label)).value, isTrue);
      expect(_errorRow(), findsOneWidget);
      expect(find.textContaining('change the canvas'), findsOneWidget);
    });
  });

  group('Voice call row', () {
    testWidgets('a canvas channel offers it, and no Canvas or Join muted', (
      tester,
    ) async {
      await _open(tester, channel: _canvas(call: false));
      expect(find.text('Voice call'), findsOneWidget);
      expect(find.text('Lets people talk while they work.'), findsOneWidget);
      expect(find.text('Canvas'), findsNothing);
      expect(find.text('Join muted'), findsNothing);
      expect(find.text('Discard canvas...'), findsNothing);
    });

    testWidgets('an older server hides it', (tester) async {
      await _open(tester, channel: _canvas(call: false), canvasChannels: false);
      expect(find.text('Voice call'), findsNothing);
    });

    testWidgets('turning it on saves voice_enabled true', (tester) async {
      final f = await _open(tester, channel: _canvas(call: false));
      await tester.tap(_toggle('Let people call in this channel'));
      await pumpFrames(tester, frames: 30);

      expect(f.patches, [
        {'voice_enabled': true},
      ]);
      expect(
        tester
            .widget<AppToggle>(_toggle('Let people call in this channel'))
            .value,
        isTrue,
      );
    });

    testWidgets('a failed save rolls back with the error on the row', (
      tester,
    ) async {
      await _open(tester, channel: _canvas(call: false), failPatch: true);
      await tester.tap(_toggle('Let people call in this channel'));
      await pumpFrames(tester, frames: 30);

      expect(
        tester
            .widget<AppToggle>(_toggle('Let people call in this channel'))
            .value,
        isFalse,
      );
      expect(_errorRow(), findsOneWidget);
    });
  });

  group('Discard hidden canvas row', () {
    testWidgets('is absent while the canvas is on', (tester) async {
      await _open(tester, channel: _voice(canvas: true));
      expect(find.text('Discard canvas...'), findsNothing);
    });

    testWidgets('shows while the canvas is off', (tester) async {
      await _open(tester, channel: _voice(canvas: false));
      expect(find.text('Discard canvas...'), findsOneWidget);
      expect(
        find.text("Removes everything on this channel's hidden board."),
        findsOneWidget,
      );
    });

    testWidgets('sits in the Danger zone above Delete channel', (tester) async {
      await _open(tester, channel: _voice(canvas: false));
      final danger = tester.getTopLeft(find.text('Danger zone')).dy;
      final discard = tester.getTopLeft(find.text('Discard canvas...')).dy;
      final delete = tester.getTopLeft(find.text('Delete channel...')).dy;
      expect(danger, lessThan(discard));
      expect(discard, lessThan(delete));
    });

    testWidgets('leaves only Delete channel when the gate is false', (
      tester,
    ) async {
      await _open(tester, channel: _voice(canvas: true));
      expect(find.text('Danger zone'), findsOneWidget);
      expect(find.text('Delete channel...'), findsOneWidget);
      expect(find.text('Discard canvas...'), findsNothing);
    });

    testWidgets('appears once the canvas is switched off here', (tester) async {
      await _open(tester, channel: _voice(canvas: true));
      await tester.tap(_toggle('Add a canvas to this channel'));
      await pumpFrames(tester, frames: 30);

      expect(find.text('Discard canvas...'), findsOneWidget);
    });

    testWidgets('needs MANAGE_CANVAS', (tester) async {
      await _open(
        tester,
        channel: _voice(canvas: false),
        permissions: Perm.manageChannels,
      );
      expect(find.text('Canvas'), findsOneWidget);
      expect(find.text('Discard canvas...'), findsNothing);
    });

    testWidgets('asks first, in the danger tone, and Cancel sends nothing', (
      tester,
    ) async {
      final f = await _open(tester, channel: _voice(canvas: false));
      await tester.tap(find.text('Discard canvas...'));
      await pumpFrames(tester, frames: 30);

      expect(find.text('Discard the hidden canvas?'), findsOneWidget);
      expect(
        find.text('Everything on it is removed, locked items too.'),
        findsOneWidget,
      );
      final discard = tester.widget<AppButton>(
        find.byWidgetPredicate((w) => w is AppButton && w.label == 'Discard'),
      );
      expect(discard.variant, AppButtonVariant.danger);

      await tester.tap(find.text('Cancel'));
      await pumpFrames(tester, frames: 30);
      expect(f.patches, isEmpty);
      expect(find.text('Discard the hidden canvas?'), findsNothing);
    });

    testWidgets('confirming sends discard_canvas and confirms with a toast', (
      tester,
    ) async {
      final f = await _open(tester, channel: _voice(canvas: false));
      await tester.tap(find.text('Discard canvas...'));
      await pumpFrames(tester, frames: 30);
      await tester.tap(
        find.byWidgetPredicate((w) => w is AppButton && w.label == 'Discard'),
      );
      await pumpFrames(tester, frames: 30);

      expect(f.patches, [
        {'discard_canvas': true},
      ]);
      expect(_errorRow(), findsNothing);
      expect(
        [for (final t in _container(tester).read(toastsProvider)) t.message],
        ['Hidden canvas discarded.'],
      );
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a failure stays on the row and raises no toast', (
      tester,
    ) async {
      await _open(tester, channel: _voice(canvas: false), failPatch: true);
      await tester.tap(find.text('Discard canvas...'));
      await pumpFrames(tester, frames: 30);
      await tester.tap(
        find.byWidgetPredicate((w) => w is AppButton && w.label == 'Discard'),
      );
      await pumpFrames(tester, frames: 30);

      expect(_errorRow(), findsOneWidget);
      expect(find.textContaining('discard the hidden canvas'), findsOneWidget);
      expect(_container(tester).read(toastsProvider), isEmpty);
    });
  });
}
