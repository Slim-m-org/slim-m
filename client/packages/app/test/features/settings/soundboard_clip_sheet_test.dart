// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A clip's emoji, in its Soundboard row and in the sheet a clip is made or
/// edited in, and the sheet's own Listen and Replace.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/emoji/widgets/custom_emoji_image.dart';
import 'package:slimm_app/src/features/settings/screens/admin/soundboard_intake.dart';

import '../../support/async_wait.dart';
import 'soundboard_harness.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('editing saves the name and the emoji together', (tester) async {
    final wire = SoundboardWire();
    wire.clips[0]['emoji'] = '\u{1F4EF}';
    await pumpSoundboard(tester, wire);
    await tester.tap(find.bySemanticsLabel('Edit Air horn'));
    await pumpFrames(tester, frames: 20);

    expect(find.text('Edit Air horn'), findsWidgets);
    expect(find.text(':postal_horn:'), findsOneWidget);
    expect(
      tester.getRect(sheetSaveButton).width,
      moreOrLessEquals(tester.getRect(clipNameField).width, epsilon: 40),
      reason: 'Save spans the sheet',
    );
    await tester.tap(sheetSaveButton);
    await pumpFrames(tester);
    expect(wire.writes, isEmpty, reason: 'nothing changed yet');

    await tester.enterText(clipNameField, 'Honk');
    await tester.tap(find.bySemanticsLabel('Clear the emoji'));
    await pumpFrames(tester);
    expect(find.text('No emoji'), findsOneWidget);
    await tester.tap(sheetSaveButton);
    await waitUntil(tester, () => wire.writes.isNotEmpty);
    await pumpFrames(tester);

    expect(wire.writes, ['PATCH Honk null']);
    expect(find.text('Honk'), findsOneWidget);
  });

  testWidgets('a row leads with its emoji and says who added it', (
    tester,
  ) async {
    final wire = SoundboardWire(custom: true);
    wire.clips[0]
      ..['emoji'] = partyEmojiId
      ..['uploader_id'] = 'user-nick';
    await pumpSoundboard(tester, wire);
    await waitUntil(
      tester,
      () => find.text('1.5 s · added by Nick').evaluate().isNotEmpty,
    );

    final image = find.byWidgetPredicate(
      (w) => w is CustomEmojiImage && w.emojiId == partyEmojiId,
    );
    expect(image, findsOneWidget);
    expect(
      tester.getRect(image).right,
      lessThan(tester.getRect(find.text('Air horn')).left),
      reason: 'where an emoji row has its image',
    );
    final listen = tester.getRect(find.bySemanticsLabel('Listen to Air horn'));
    final edit = tester.getRect(find.bySemanticsLabel('Edit Air horn'));
    final remove = tester.getRect(find.bySemanticsLabel('Remove Air horn'));
    expect(listen.right, lessThanOrEqualTo(edit.left));
    expect(edit.right, lessThanOrEqualTo(remove.left));
    expect(listen.center.dy, moreOrLessEquals(remove.center.dy, epsilon: 1));
  });

  testWidgets('the add sheet sends the standard emoji chosen in it', (
    tester,
  ) async {
    final wire = SoundboardWire();
    await pumpSoundboard(
      tester,
      wire,
      pick: const SoundClipPick(fileName: 'grin.mp3', bytes: [1, 2]),
    );
    await openCreateClip(tester);
    expect(find.text('No emoji'), findsOneWidget);

    await tester.tap(clipEmojiButton);
    await pumpFrames(tester, frames: 20);
    await tester.tap(find.text(grinningFace).first);
    await pumpFrames(tester, frames: 20);
    expect(find.text(':grinning:'), findsOneWidget);

    await tester.tap(sheetCreateButton);
    await waitUntil(tester, () => wire.writes.isNotEmpty);
    expect(wire.writes, ['POST grin 2 $grinningFace']);
  });

  testWidgets("a custom emoji chosen in the add sheet is sent as its id", (
    tester,
  ) async {
    final wire = SoundboardWire(custom: true);
    await pumpSoundboard(
      tester,
      wire,
      pick: const SoundClipPick(fileName: 'parrot.wav', bytes: [1]),
    );
    await openCreateClip(tester);

    await tester.tap(clipEmojiButton);
    await pumpFrames(tester, frames: 20);
    await tester.tap(
      find
          .byWidgetPredicate(
            (w) => w is CustomEmojiImage && w.emojiId == partyEmojiId,
          )
          .last,
    );
    await pumpFrames(tester, frames: 20);
    expect(find.text(':party_parrot:'), findsOneWidget);

    await tester.tap(sheetCreateButton);
    await waitUntil(tester, () => wire.writes.isNotEmpty);
    expect(wire.writes, ['POST parrot 1 $partyEmojiId']);
  });

  testWidgets('the add sheet plays the chosen file and can swap it', (
    tester,
  ) async {
    final wire = SoundboardWire();
    final player = RecordingClipPlayer();
    await pumpSoundboard(
      tester,
      wire,
      player: player,
      picks: const [
        SoundClipPick(fileName: 'first.mp3', bytes: [7]),
        SoundClipPick(fileName: 'second.wav', bytes: [8, 9]),
      ],
    );
    await openCreateClip(tester);

    await tester.tap(find.bySemanticsLabel('Listen to first.mp3'));
    await waitUntil(tester, () => player.played.isNotEmpty);
    expect(player.played.single.bytes, [7]);
    expect(player.played.single.mimeType, 'audio/mpeg');

    await tester.tap(find.bySemanticsLabel('Choose another file'));
    await pumpFrames(tester, frames: 20);
    expect(find.text('second.wav'), findsOneWidget);
    expect(
      tester.widget<EditableText>(clipNameField).controller.text,
      'second',
    );

    await tester.tap(sheetCreateButton);
    await waitUntil(tester, () => wire.writes.isNotEmpty);
    expect(wire.writes, ['POST second 2'], reason: 'nothing reached a call');
  });
}
