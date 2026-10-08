// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one emoji add card: images, zips and a mix become a single review
/// list, then upload in one action, with every refusal named per file.
library;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'package:slimm_app/src/screens/admin/emoji_intake.dart';

import 'emoji_add_harness.dart';

EmojiHarness _bulkOk(
  List<String> picked, {
  List<api.CustomEmoji> existing = const [],
}) => EmojiHarness(
  existing: existing,
  picks: [for (final n in picked) emojiPick(n)],
  onBulk: (r) =>
      emojiJson([for (final n in bulkNames(r)) emojiRow(n)], status: 201),
  onSingle: (r) =>
      emojiJson(emojiRow(r.url.queryParameters['name']!), status: 201),
);

Finder get _nameFields => find.byType(TextField);

void main() {
  testWidgets('three picked PNGs become one review list and one upload', (
    tester,
  ) async {
    final h = _bulkOk(['Party Blob.png', 'zorg.png', 'quux.png']);
    await h.pump(tester);
    await h.choose(tester);

    expect(_nameFields, findsNWidgets(3));
    expect(find.text('Add 3 emoji'), findsOneWidget);
    await tester.tap(find.text('Add 3 emoji'));
    await tester.pumpAndSettle();

    expect(h.bulks, hasLength(1));
    expect(bulkNames(h.bulks.single), ['party_blob', 'zorg', 'quux']);
    expect(find.textContaining('Added 3 of 3'), findsOneWidget);
    expect(_nameFields, findsNothing);
  });

  testWidgets('a mix of an image and a zip is one list, junk named once', (
    tester,
  ) async {
    final h = _bulkOk(const []);
    h.picks = [
      emojiPick('solo.png'),
      EmojiPick(
        fileName: 'pack.zip',
        bytes: buildEmojiZip({
          'icons/aaa.png': emojiTestPng,
          'bbb.gif': emojiTestPng,
          'readme.txt': [1, 2],
        }),
      ),
    ];
    await h.pump(tester);
    await h.choose(tester);

    expect(_nameFields, findsNWidgets(3));
    expect(find.text('Add 3 emoji'), findsOneWidget);
    await tester.tap(find.text('Add 3 emoji'));
    await tester.pumpAndSettle();

    expect(bulkNames(h.bulks.single), ['solo', 'aaa', 'bbb']);
    expect(find.textContaining('Added 3 of 4'), findsOneWidget);
    expect(
      find.textContaining('readme.txt: not a PNG, JPEG, GIF or WEBP image'),
      findsOneWidget,
    );
  });

  testWidgets('dropping files fills the same review list', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final h = _bulkOk(const []);
    await h.pump(tester);

    final target = tester.widget<DropTarget>(find.byType(DropTarget));
    target.onDragDone!(
      DropDoneDetails(
        files: [
          DropItemFile.fromData(emojiTestPng, path: 'one.png'),
          DropItemFile.fromData(emojiTestPng, path: 'two.webp'),
          DropItemFile.fromData(Uint8List.fromList([1]), path: 'notes.txt'),
        ],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    await tester.pumpAndSettle();

    expect(_nameFields, findsNWidgets(2));
    expect(
      find.textContaining('notes.txt: not a PNG'),
      findsOneWidget,
      reason: 'refusals are named before anything uploads',
    );
    await tester.tap(find.text('Add 2 emoji'));
    await tester.pumpAndSettle();
    expect(find.textContaining('notes.txt: not a PNG'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a name is editable, normalised, and a bad one blocks upload', (
    tester,
  ) async {
    final h = _bulkOk(
      ['blah.png', 'blob.png'],
      existing: const [
        api.CustomEmoji(id: 'e1', name: 'taken', uploaderId: 'u', createdAt: 0),
      ],
    );
    await h.pump(tester);
    await h.choose(tester);

    await tester.enterText(_nameFields.first, 'taken');
    await tester.pump();
    expect(find.text('Already taken.'), findsOneWidget);
    expect(
      tester
          .widget<AppButton>(find.widgetWithText(AppButton, 'Add 2 emoji'))
          .disabled,
      isTrue,
    );

    await tester.enterText(_nameFields.first, 'bug');
    await tester.pump();
    expect(find.text('That is a standard emoji.'), findsOneWidget);

    await tester.enterText(_nameFields.first, 'blob');
    await tester.pump();
    expect(find.text('Another image has this name.'), findsOneWidget);

    await tester.enterText(_nameFields.first, 'Party Parrot');
    await tester.pump();
    await tester.tap(find.text('Add 2 emoji'));
    await tester.pumpAndSettle();
    expect(bulkNames(h.bulks.single), ['party_parrot', 'blob']);
  });

  testWidgets('one image uses the single route and reports a 409 reason', (
    tester,
  ) async {
    final h = EmojiHarness(
      picks: [emojiPick('blorp.png')],
      onSingle: (r) => emojiJson({
        'error': 'an emoji with that name already exists',
      }, status: 409),
    );
    await h.pump(tester);
    await h.choose(tester);
    await tester.tap(find.text('Add 1 emoji'));
    await tester.pumpAndSettle();

    expect(h.singles.single.url.queryParameters['name'], 'blorp');
    expect(h.bulks, isEmpty);
    expect(
      find.textContaining('an emoji with that name already exists'),
      findsOneWidget,
    );
    expect(
      _nameFields,
      findsOneWidget,
      reason: 'the failed image stays to retry',
    );
  });

  testWidgets('an identical image is reported and can be taken back', (
    tester,
  ) async {
    final h = EmojiHarness(
      picks: [emojiPick('parrot_b.png')],
      onSingle: (r) =>
          emojiJson(emojiRow('parrot_b', sameImageAs: 'parrot_a'), status: 201),
      onBulk: (r) => emojiJson(const {}),
    );
    await h.pump(tester);
    await h.choose(tester);
    await tester.tap(find.text('Add 1 emoji'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(':parrot_b: was added, but it is the same'),
      findsOneWidget,
    );
    await tester.tap(find.text('Use :parrot_a: instead'));
    await tester.pumpAndSettle();
    expect(
      h.requests.map((r) => '${r.method} ${r.url.path}'),
      contains('DELETE /emoji/e-parrot_b'),
    );
  });

  testWidgets('over the request cap splits, and a failed chunk retries alone', (
    tester,
  ) async {
    var calls = 0;
    final h = EmojiHarness(
      picks: [for (var i = 0; i < 60; i++) emojiPick('e$i.png')],
      onBulk: (r) {
        calls++;
        final names = bulkNames(r);
        if (names.length == 10 && calls <= 2) {
          return emojiJson({
            'error': 'too many requests just now.',
          }, status: 429);
        }
        return emojiJson([for (final n in names) emojiRow(n)], status: 201);
      },
    );
    await h.pump(tester);
    await h.choose(tester);
    await tester.tap(find.text('Add 60 emoji'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.textContaining('Added 50 of 60'), findsOneWidget);
    expect(
      find.textContaining('10 images could not be added:'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Add 10 emoji'));
    await tester.tap(find.text('Add 10 emoji'));
    await tester.pumpAndSettle();

    expect(calls, 3);
    expect(find.textContaining('Added 60 of 60'), findsOneWidget);
    expect(find.text('Add 10 emoji'), findsNothing);
  });

  testWidgets('wrong, oversize and empty files are each named', (tester) async {
    final h = _bulkOk(const []);
    h.picks = [
      emojiPick('big.png', List.filled(1024 * 1024 + 1, 1)),
      emojiPick('empty.png', const []),
      emojiPick('fine.png'),
    ];
    await h.pump(tester);
    await h.choose(tester);

    await tester.tap(find.text('Add 1 emoji'));
    await tester.pumpAndSettle();
    expect(find.textContaining('big.png: larger than 1 MB'), findsOneWidget);
    expect(find.textContaining('empty.png: the file is empty'), findsOneWidget);
  });

  testWidgets('a zip with no images is refused inline', (tester) async {
    final h = _bulkOk(const []);
    h.picks = [
      EmojiPick(fileName: 'empty.zip', bytes: buildEmojiZip(const {})),
    ];
    await h.pump(tester);
    await h.choose(tester);
    expect(find.text('No images found.'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a failing picker is refused inline', (tester) async {
    final broken = EmojiHarness(pickerThrows: true);
    await broken.pump(tester);
    await broken.choose(tester);
    expect(
      find.textContaining('Could not open the file picker'),
      findsOneWidget,
    );
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a phone width lays the review out without overflow', (
    tester,
  ) async {
    final h = _bulkOk(['a_long_emoji_file_name.png', 'b.png']);
    await h.pump(tester, size: const Size(390, 844));
    await h.choose(tester);
    expect(tester.takeException(), isNull);
    expect(tester.getSize(_nameFields.first).width, lessThan(390));
  });
}
