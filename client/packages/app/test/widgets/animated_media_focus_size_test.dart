// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A link preview's gif and an animated emoji or sticker keep their size while
/// the window loses and regains focus: the gate pauses them in place rather
/// than swapping in a still, which is what made an inline gif jump.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/emoji/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/features/emoji/widgets/custom_emoji_image.dart';
import 'package:slimm_app/src/features/messages/providers/link_preview.dart';
import 'package:slimm_app/src/features/messages/widgets/link_preview_thumbnail.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

const _mediaKey = Key('focus-size-media');

/// A real gif with a 220 x 165 logical screen.
Uint8List _gif() {
  final bytes = base64Decode(
    'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
  );
  ByteData.sublistView(bytes)
    ..setUint16(6, 220, Endian.little)
    ..setUint16(8, 165, Endian.little);
  return bytes;
}

final _painted = find.descendant(
  of: find.byKey(_mediaKey),
  matching: find.byWidgetPredicate((w) => w is RawImage && w.image != null),
);

Future<Size> _settledSize(WidgetTester tester) async {
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    if (_painted.evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 50));
      return tester.getSize(find.byKey(_mediaKey));
    }
  }
  fail('no frame was ever painted');
}

void _setFocused(bool focused) =>
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      focused ? AppLifecycleState.resumed : AppLifecycleState.inactive,
    );

Future<void> _expectSteadyAcrossFocus(
  WidgetTester tester,
  List<Override> overrides,
  Widget media,
) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith(
        (ref) => SharedPreferences.getInstance(),
      ),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: KeyedSubtree(key: _mediaKey, child: media),
          ),
        ),
      ),
    ),
  );
  final focused = await _settledSize(tester);
  _setFocused(false);
  await tester.pump();
  expect(tester.getSize(find.byKey(_mediaKey)), focused);
  expect(await _settledSize(tester), focused);
  _setFocused(true);
  expect(await _settledSize(tester), focused);
}

void main() {
  setUp(() => addTearDown(() => _setFocused(true)));

  testWidgets('a link preview gif keeps its size across focus', (tester) async {
    await _expectSteadyAcrossFocus(tester, [
      linkPreviewImageBytesProvider('t1').overrideWith((ref) async => _gif()),
    ], const LinkPreviewThumbnail(token: 't1', url: 'https://example.com/a'));
  });

  testWidgets('a bounded link preview gif keeps its size across focus', (
    tester,
  ) async {
    await _expectSteadyAcrossFocus(
      tester,
      [linkPreviewImageBytesProvider('t2').overrideWith((ref) async => _gif())],
      const LinkPreviewThumbnail(
        token: 't2',
        url: 'https://example.com/b',
        bounds: Size(160, 160),
      ),
    );
  });

  testWidgets('an animated emoji or sticker keeps its size across focus', (
    tester,
  ) async {
    await _expectSteadyAcrossFocus(tester, [
      customEmojiImageProvider('e1').overrideWith((ref) async => _gif()),
    ], const CustomEmojiImage(emojiId: 'e1', size: 96));
  });
}
