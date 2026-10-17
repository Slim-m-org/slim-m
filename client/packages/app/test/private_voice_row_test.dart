// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A private voice row leads with the speaker carrying the private lock, so
/// it reads as voice at a glance, and keeps only the join-muted mic-off at
/// its trailing end, clear of the user-limit count and the hover kebab at the
/// narrowest rail width. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/rail_width_preference.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_channel_rows.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';
import 'voice_controller_harness.dart';

Channel _voice(
  String name, {
  bool restricted = false,
  bool joinMuted = false,
  bool lobby = false,
  bool locked = false,
  int? limit,
  bool unread = false,
}) => Channel(
  id: 'ch-$name',
  name: name,
  kind: 'voice',
  createdAt: 0,
  position: 0,
  cursor: unread ? 3 : 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: joinMuted,
  isPersonalSpace: false,
  restricted: restricted,
  createsRooms: lobby ? true : null,
  roomLocked: locked ? true : null,
  userLimit: limit,
);

Widget _row(Channel c, {bool selected = false}) => ManagedChannelRow(
  canManage: true,
  reorderable: false,
  channel: c,
  row: (kebab) =>
      VoiceChannelRow(channel: c, selected: selected, trailingExtra: kebab),
);

Future<void> _pump(WidgetTester tester, List<Widget> rows, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => FixedVoiceController(ref, const VoiceState()),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: AppTouchTargets(
            enabled: size.width >= 390,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: size.width,
                child: Column(children: rows),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a private voice row leads with the locked speaker, not a hash', (
    tester,
  ) async {
    final c = _voice('staff', restricted: true);
    await _pump(tester, [_row(c)], const Size(railMinWidth, 200));
    final row = find.byType(AppListRow);
    final lock = find.descendant(
      of: row,
      matching: find.byIcon(AppIcons.restrictedChannel),
    );
    final speaker = find.descendant(
      of: row,
      matching: find.byIcon(AppIcons.voice),
    );
    expect(find.byIcon(AppIcons.hash), findsNothing);
    expect(lock, findsOneWidget);
    expect(speaker, findsOneWidget, reason: 'one speaker, leading');
    final rect = tester.getRect(row);
    expect(tester.getRect(speaker).left, lessThan(rect.center.dx));
    expect(tester.getRect(lock).left, lessThan(rect.center.dx));
  });

  testWidgets('a public voice row keeps the speaker leading', (tester) async {
    await _pump(tester, [
      _row(_voice('general')),
    ], const Size(railMinWidth, 200));
    expect(find.byIcon(AppIcons.hash), findsNothing);
    expect(find.byIcon(AppIcons.restrictedChannel), findsNothing);
    final row = tester.getRect(find.byType(AppListRow));
    expect(
      tester.getRect(find.byIcon(AppIcons.voice)).left,
      lessThan(row.center.dx),
    );
  });

  testWidgets(
    'the trailing pair clears the limit count and the kebab at min width',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final c = _voice(
        'a-rather-long-private-room',
        restricted: true,
        joinMuted: true,
        locked: true,
        limit: 12,
      );
      await _pump(tester, [_row(c)], const Size(railMinWidth, 200));
      final mic = tester.getRect(find.byIcon(AppIcons.micOff));
      final lock = tester.getRect(find.byIcon(AppIcons.roomLocked));
      final count = tester.getRect(find.text('0/12'));
      final kebab = tester.getRect(find.byIcon(AppIcons.moreVertical));
      final row = tester.getRect(find.byType(AppListRow));
      final label = tester.getRect(find.text('a-rather-long-private-room'));
      expect(lock.right, lessThanOrEqualTo(count.left));
      expect(count.right, lessThanOrEqualTo(mic.left));
      expect(mic.right, lessThanOrEqualTo(kebab.left));
      expect(kebab.right, lessThanOrEqualTo(row.right));
      expect(label.right, lessThanOrEqualTo(lock.left));
      expect(
        tester.getSemantics(find.byType(AppListRow)).label,
        allOf(contains('Private voice channel'), contains('Joins muted')),
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'a private voice row that does not join muted says so truthfully',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, [
        _row(_voice('staff', restricted: true)),
      ], const Size(390, 200));
      expect(find.byIcon(AppIcons.micOff), findsNothing);
      final label = tester.getSemantics(find.byType(AppListRow)).label;
      expect(label, contains('Private voice channel'));
      expect(label, isNot(contains('Joins muted')));
      semantics.dispose();
    },
  );

  testWidgets('a private lobby keeps the lobby glyph leading', (tester) async {
    await _pump(tester, [
      _row(_voice('rooms', restricted: true, lobby: true)),
    ], const Size(railMinWidth, 200));
    expect(find.byIcon(AppIcons.voiceLobby), findsOneWidget);
    expect(find.byIcon(AppIcons.voice), findsNothing);
  });

  final rows = <Widget>[
    _row(_voice('public')),
    _row(_voice('public-muted', joinMuted: true)),
    _row(_voice('private', restricted: true)),
    _row(
      _voice('private-muted', restricted: true, joinMuted: true),
      selected: true,
    ),
    _row(
      _voice(
        'private-unread',
        restricted: true,
        joinMuted: true,
        unread: true,
        limit: 8,
      ),
    ),
    _row(_voice('lobby', lobby: true)),
    _row(_voice('room-locked', locked: true, limit: 4)),
  ];
  setUpAll(loadRealFonts);
  for (final brightness in Brightness.values) {
    for (final (label, size) in [
      ('rail-min', const Size(railMinWidth, 400)),
      ('desktop', const Size(260, 400)),
      ('phone', const Size(390, 400)),
    ]) {
      final name = 'private-voice-row-$label-${brightness.name}';
      testWidgets(name, (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              voiceControllerProvider.overrideWith(
                (ref) => FixedVoiceController(ref, const VoiceState()),
              ),
            ],
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildTheme(
                brightness,
                brightness == Brightness.dark
                    ? AppTokens.dark
                    : AppTokens.light,
              ),
              home: RepaintBoundary(
                key: snapshotBoundary,
                child: Scaffold(
                  body: AppTouchTargets(
                    enabled: label == 'phone',
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: size.width,
                        child: Column(children: rows),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 350));
        await expectSettled(tester, name, allowNoText: false);
        await writeSnapshot(tester, name);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
