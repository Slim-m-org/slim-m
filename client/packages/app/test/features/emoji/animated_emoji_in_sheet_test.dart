// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An animated custom emoji has to move inside the sheet that shows it.
///
/// The owner opened the phone's emoji sheet and none of the animated emoji in
/// it played. The sheet is itself a non-opaque route on the root navigator,
/// and the animation gate froze every image while any such route was open,
/// the sheet's own included.
library;

import 'dart:convert';

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
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../composer/composer_harness.dart' show emojiButton;
import '../settings/home_shell_harness.dart';

/// Two 1x1 frames, red then blue, 100ms apart, looping forever.
final _twoFrameGif = base64Decode(
  'R0lGODlhAQABAIAAAP8AAAAA/yH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAQABAAAC'
  'AkQBACH5BAAKAAAALAAAAAABAAEAAAICTAEAOw==',
);

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

/// The distinct frames drawn over [steps] rounds that give the real-time decode and the fake-time frame timer a turn each.
///
/// A looping gif hands out a fresh image per frame, so two handles are two frames.
Future<Set<int>> _framesDrawn(WidgetTester tester, {int steps = 12}) async {
  final frames = <int>{};
  for (var i = 0; i < steps; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 60));
    for (final drawn in _drawnImages(tester)) {
      if (drawn.image != null) frames.add(drawn.image.hashCode);
    }
  }
  return frames;
}

/// Opens the composer's own picker in the real app router on a phone, the way the owner hit it.
///
/// Returns what the test must await last: the shell holds timers a plain tear-down would leave pending.
Future<Future<void> Function()> _openComposerSheet(WidgetTester tester) async {
  final s = setup(
    httpClient: quietClient(),
    signedIn: true,
    extraOverrides: [
      initialSyncCompleteProvider.overrideWith((ref) => true),
      customEmojiProvider.overrideWith((ref) async => const [_party]),
      customEmojiImageProvider.overrideWith((ref, id) async => _twoFrameGif),
    ],
  );
  s.container
      .read(chosenServerProvider.notifier)
      .restore(Uri.parse('http://localhost:8080'));
  await MessageStore(s.db).upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
  ]);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = s.container.read(routerProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: s.container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  router.go(Routes.channel('c1'));
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.tap(emojiButton);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  return () => teardown(tester, s.container, s.db);
}

/// A phone-width page in a nested navigator, as the shell's pages are, with a button that calls [open].
Future<Future<void> Function()> _openFrom(
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
  return () async {};
}

final _sheets =
    <String, Future<Future<void> Function()> Function(WidgetTester)>{
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
  // One gif's bytes are one cache key, and its frame timer belongs to the test that started it.
  setUp(() {
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  for (final MapEntry(key: name, value: open) in _sheets.entries) {
    testWidgets('an animated emoji in $name plays', (tester) async {
      final finish = await open(tester);
      final frames = await _framesDrawn(tester);

      final shown = _drawnImages(tester);
      expect(shown, hasLength(1), reason: 'the one custom emoji in the grid');
      expect(
        TickerMode.valuesOf(_contextOf(shown.single)).enabled,
        isTrue,
        reason: 'the sheet is the topmost route, so nothing covers its emoji',
      );
      expect(
        frames.length,
        greaterThan(1),
        reason: 'the emoji must move, not hold its first frame',
      );
      await finish();
    });
  }
}
