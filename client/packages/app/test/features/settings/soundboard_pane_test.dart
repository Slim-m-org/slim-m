// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space settings Soundboard section: the list, creating from a file,
/// the rules a file and a name are held to, listening and removing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/settings/screens/admin/soundboard_intake.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import 'soundboard_harness.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('lists the clips with their lengths under a plain title', (
    tester,
  ) async {
    await pumpSoundboard(tester, SoundboardWire());
    expect(find.text('Clips'), findsOneWidget);
    expect(find.text('1 of 48'), findsOneWidget);
    expect(find.text('Air horn'), findsOneWidget);
    expect(find.text('1.5 s'), findsOneWidget);
  });

  testWidgets('every clip is laid out in the page, not a box cut short', (
    tester,
  ) async {
    final wire = SoundboardWire();
    wire.clips.addAll([
      for (var i = 2; i <= 40; i++)
        {'id': 'c$i', 'name': 'Clip $i', 'duration_ms': 900, 'created_at': i},
    ]);
    await pumpSoundboard(tester, wire);

    expect(find.text('Clip 40', skipOffstage: false), findsOneWidget);
  });

  testWidgets('on a phone the clips start just under the title bar', (
    tester,
  ) async {
    await pumpSoundboard(tester, SoundboardWire(), width: 390);
    final gap =
        tester.getTopLeft(find.text('Clips')).dy -
        tester.getBottomLeft(soundboardTitleBar).dy;

    expect(gap, AppSpacing.s16 + AppSpacing.s8);
  });

  testWidgets(
    'a clip the server seeded with no uploader renders like any other',
    (tester) async {
      await pumpSoundboard(tester, SoundboardWire(seeded: true));
      expect(find.text('Rimshot'), findsOneWidget);
      expect(find.text('0.8 s'), findsOneWidget);
      expect(find.bySemanticsLabel('Edit Rimshot'), findsOneWidget);
      expect(find.byIcon(AppIcons.music), findsNWidgets(2), reason: 'no emoji');
      expect(find.text('2 of 48'), findsOneWidget);
    },
  );

  testWidgets('Create clip sits in the title bar at its own width', (
    tester,
  ) async {
    await pumpSoundboard(tester, SoundboardWire());
    expect(soundboardCreateButton, findsOneWidget);
    final bar = tester.getRect(soundboardTitleBar);
    final button = tester.getRect(soundboardCreateButton);
    expect(bar.contains(button.center), isTrue);
    expect(
      button.width,
      lessThan(bar.width / 3),
      reason: 'never a full-width bar',
    );
  });

  testWidgets('creating asks for a name first, prefilled from the file', (
    tester,
  ) async {
    final wire = SoundboardWire();
    await pumpSoundboard(
      tester,
      wire,
      pick: SoundClipPick(
        fileName: 'sad trombone.mp3',
        bytes: List.filled(1000, 1),
      ),
    );
    await openCreateClip(tester);

    expect(wire.writes, isEmpty, reason: 'nothing is sent before it is named');
    expect(find.text('sad trombone.mp3'), findsOneWidget);
    expect(
      tester.widget<EditableText>(clipNameField).controller.text,
      'sad trombone',
    );

    await tester.enterText(clipNameField, 'Trombone');
    await tester.pump();
    await tester.tap(sheetCreateButton);
    await waitUntil(tester, () => wire.writes.isNotEmpty);
    await pumpFrames(tester);

    expect(wire.writes, ['POST Trombone 1000']);
    expect(find.text('Trombone'), findsOneWidget);
    expect(find.text('sad trombone.mp3'), findsNothing, reason: 'closed');
  });

  testWidgets('a taken name is flagged before sending and fixed in place', (
    tester,
  ) async {
    final wire = SoundboardWire();
    await pumpSoundboard(
      tester,
      wire,
      pick: const SoundClipPick(fileName: 'AIR HORN.wav', bytes: [1]),
    );
    await openCreateClip(tester);

    expect(find.text('A clip already has that name.'), findsOneWidget);
    await tester.tap(sheetCreateButton);
    await pumpFrames(tester);
    expect(wire.writes, isEmpty, reason: 'a taken name is never sent');

    await tester.enterText(clipNameField, 'Air horn 2');
    await tester.pump();
    expect(find.text('A clip already has that name.'), findsNothing);
    await tester.tap(sheetCreateButton);
    await waitUntil(tester, () => wire.writes.isNotEmpty);

    expect(wire.writes, ['POST Air horn 2 1']);
  });

  testWidgets("the server's refusal stays on the sheet with the file kept", (
    tester,
  ) async {
    final wire = SoundboardWire()
      ..uploadFailure = 'clip must be at most 5 seconds';
    await pumpSoundboard(
      tester,
      wire,
      pick: const SoundClipPick(fileName: 'long.wav', bytes: [1, 2]),
    );
    await openCreateClip(tester);
    await tester.tap(sheetCreateButton);
    await waitUntil(tester, () => wire.writes.isNotEmpty);
    await pumpFrames(tester);

    expect(find.textContaining('Could not create the clip'), findsOneWidget);
    expect(find.text('long.wav'), findsOneWidget, reason: 'still open');

    wire.uploadFailure = null;
    await tester.tap(sheetCreateButton);
    await waitUntil(tester, () => wire.writes.length == 2);
    await pumpFrames(tester);

    expect(wire.writes, ['POST long 2', 'POST long 2']);
    expect(find.text('long.wav'), findsNothing);
  });

  testWidgets('a file over 512 KB is refused before it is sent', (
    tester,
  ) async {
    final wire = SoundboardWire();
    await pumpSoundboard(
      tester,
      wire,
      pick: SoundClipPick(
        fileName: 'huge.wav',
        bytes: List.filled(512 * 1024 + 1, 0),
      ),
    );
    await openCreateClip(tester);
    await tester.tap(sheetCreateButton);
    await pumpFrames(tester);

    expect(wire.writes, isEmpty);
    expect(find.textContaining('over 512 KB'), findsOneWidget);
  });

  testWidgets('listening plays the clip here and sends nothing to a call', (
    tester,
  ) async {
    final wire = SoundboardWire();
    final player = RecordingClipPlayer();
    await pumpSoundboard(tester, wire, player: player);

    await tester.tap(find.bySemanticsLabel('Listen to Air horn'));
    await waitUntil(tester, () => player.played.isNotEmpty);

    expect(player.played.single.bytes, [1, 2, 3]);
    expect(player.played.single.mimeType, 'audio/wav');
    expect(wire.writes, isEmpty, reason: 'no /play reaches the server');
  });

  testWidgets('removing asks first, then deletes', (tester) async {
    final wire = SoundboardWire();
    await pumpSoundboard(tester, wire);
    await tester.tap(find.bySemanticsLabel('Remove Air horn'));
    await pumpFrames(tester, frames: 20);
    expect(wire.writes, isEmpty, reason: 'confirm first');

    await tester.tap(find.text('Remove'));
    await waitUntil(tester, () => wire.writes.isNotEmpty);
    await pumpFrames(tester);

    expect(wire.writes, ['DELETE']);
    expect(find.text('No clips yet.'), findsOneWidget);
  });
}
