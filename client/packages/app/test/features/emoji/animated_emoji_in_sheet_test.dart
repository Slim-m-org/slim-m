// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An animated custom emoji has to move inside the sheet that shows it.
///
/// The owner opened the phone's emoji sheet and none of the animated emoji in
/// it played. The sheet is itself a non-opaque route on the root navigator,
/// and the animation gate froze every image while any such route was open,
/// the sheet's own included.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/emoji/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_picker_sheets.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/overlay_cover.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../composer/composer_harness.dart' show emojiButton;
import '../settings/home_shell_harness.dart';

/// Two 1x1 frames, red then blue, 100ms apart, looping forever.
final _twoFrameGif = Uint8List.fromList([
  ...'GIF89a'.codeUnits,
  0x01,
  0x00,
  0x01,
  0x00,
  0x80,
  0x00,
  0x00,
  0xFF,
  0x00,
  0x00,
  0x00,
  0x00,
  0xFF,
  0x21,
  0xFF,
  0x0B,
  ...'NETSCAPE2.0'.codeUnits,
  0x03,
  0x01,
  0x00,
  0x00,
  0x00,
  for (final pixel in [0x44, 0x4C]) ...[
    0x21,
    0xF9,
    0x04,
    0x00,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x2C,
    0x00,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x01,
    0x00,
    0x00,
    0x02,
    0x02,
    pixel,
    0x01,
    0x00,
  ],
  0x3B,
]);

const _party = api.CustomEmoji(
  id: 'e-party',
  name: 'party',
  uploaderId: 'u1',
  createdAt: 1,
);

List<RenderImage> _drawnImages(WidgetTester tester) =>
    tester.allRenderObjects.whereType<RenderImage>().toList();

BuildContext _contextOf(RenderImage image) =>
    (image.debugCreator! as DebugCreator).element;

/// Real time for the engine's frame decode, fake time for the frame timer.
Future<void> _play(WidgetTester tester, {int steps = 12}) async {
  for (var i = 0; i < steps; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// Opens the composer's own picker through the real shell on a phone, the way the owner hit it.
Future<void> _openComposerSheet(WidgetTester tester) async {
  final s = setup(
    httpClient: quietClient(),
    signedIn: true,
    extraOverrides: [
      initialSyncCompleteProvider.overrideWith((ref) => true),
      customEmojiProvider.overrideWith((ref) async => const [_party]),
      customEmojiImageProvider.overrideWith((ref, id) async => _twoFrameGif),
    ],
  );
  addTearDown(() => teardown(tester, s.container, s.db));
  await MessageStore(s.db).upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
  ]);
  await pumpAtWidth(
    tester,
    s.container,
    390,
    location: '/channels/c1',
    observers: [
      OverlayCoverObserver(
        (n) => s.container.read(overlayCoverProvider.notifier).state = n,
      ),
    ],
  );
  await tester.tap(emojiButton);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// A phone-width page in a nested navigator, as the shell's pages are, with a button that calls [open].
Future<void> _openFrom(
  WidgetTester tester,
  Future<void> Function(BuildContext context) open,
) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      customEmojiProvider.overrideWith((ref) async => const [_party]),
      customEmojiImageProvider.overrideWith((ref, id) async => _twoFrameGif),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        navigatorObservers: [
          OverlayCoverObserver(
            (n) => container.read(overlayCoverProvider.notifier).state = n,
          ),
        ],
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => open(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

final _sheets = <String, Future<void> Function(WidgetTester)>{
  "the composer's emoji and GIF sheet": _openComposerSheet,
  'the reaction picker sheet': (tester) => _openFrom(
    tester,
    (context) => showEmojiPickerSheet(context, onSelect: (_) {}),
  ),
  "the composer's Space emoji sheet": (tester) => _openFrom(
    tester,
    (context) => showSpaceEmojiSheet(context, onSelect: (_) {}),
  ),
};

void main() {
  for (final MapEntry(key: name, value: open) in _sheets.entries) {
    testWidgets('an animated emoji in $name plays', (tester) async {
      await open(tester);
      await _play(tester, steps: 3);

      final shown = _drawnImages(tester);
      expect(shown, hasLength(1), reason: 'the one custom emoji in the grid');
      expect(
        TickerMode.valuesOf(_contextOf(shown.single)).enabled,
        isTrue,
        reason: 'the sheet is the topmost route, so nothing covers its emoji',
      );

      final first = _drawnImages(tester).single.image!;
      await _play(tester);
      final later = _drawnImages(tester).single.image!;
      expect(
        later.isCloneOf(first),
        isFalse,
        reason: 'the second frame must have replaced the first',
      );
    });
  }
}
