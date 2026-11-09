// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The personal background: importing and keeping a picture, restoring it,
/// and what the host does with it, including turning it off for high contrast.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/background/providers/app_background_controller.dart';
import 'package:slimm_app/src/features/background/providers/background_image_store.dart';
import 'package:slimm_app/src/features/background/widgets/app_background_host.dart';
import 'package:slimm_app/src/features/settings/providers/display_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

Uint8List get _forest =>
    File('test/fixtures/background_forest.png').readAsBytesSync();

Future<Uint8List> _widePng(int w, int h) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFF336644),
  );
  final image = await rec.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// Decodes the picture and keeps it, as the mounted host does by watching it.
Future<ui.Image?> _decoded(ProviderContainer c) {
  c.listen(backgroundPictureProvider, (_, _) {});
  return c.read(backgroundPictureProvider.future);
}

class _BrokenPrefs extends Fake implements SharedPreferences {
  @override
  Future<bool> setBool(String key, bool value) =>
      Future.error(StateError('disk full'));
}

ProviderContainer _container(MemoryBackgroundImageStore store) {
  final container = ProviderContainer(
    overrides: [backgroundImageStoreProvider.overrideWithValue(store)],
  );
  addTearDown(container.dispose);
  return container;
}

class _Probe extends StatefulWidget {
  const _Probe([this.builds]);

  final List<int>? builds;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final int _id = DateTime.now().microsecondsSinceEpoch;

  @override
  Widget build(BuildContext context) {
    widget.builds?.add(_id);
    return Text(
      AppBackgroundScope.paneColor(context, Colors.red).a.toStringAsFixed(2),
      textDirection: TextDirection.ltr,
    );
  }
}

Widget _host(ProviderContainer c, Widget child) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: AppBackgroundHost(child: child),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('controller', () {
    test('import keeps the picture, flags it and reads its range', () async {
      final store = MemoryBackgroundImageStore();
      final c = _container(store);
      final ok = await c
          .read(appBackgroundControllerProvider.notifier)
          .importPicture(_forest);
      final s = c.read(appBackgroundControllerProvider);
      expect(ok, isTrue);
      expect(s.hasImage, isTrue);
      expect(await store.read(), isNotNull);
      expect(
        s.range.lightest.computeLuminance(),
        greaterThan(s.range.darkest.computeLuminance()),
      );
      expect(s.range.darkest.computeLuminance(), lessThan(0.05));
    });

    test('import shrinks the longest side to 2560', () async {
      final store = MemoryBackgroundImageStore();
      final c = _container(store);
      await c
          .read(appBackgroundControllerProvider.notifier)
          .importPicture(await _widePng(3600, 900));
      final codec = await ui.instantiateImageCodec((await store.read())!);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, backgroundMaxSide);
      expect(frame.image.height, 640);
    });

    test('a failed settings write keeps no picture and says so', () async {
      final store = MemoryBackgroundImageStore();
      final c = ProviderContainer(
        overrides: [
          backgroundImageStoreProvider.overrideWithValue(store),
          preferencesProvider.overrideWith((ref) => _BrokenPrefs()),
        ],
      );
      addTearDown(c.dispose);

      final ok = await c
          .read(appBackgroundControllerProvider.notifier)
          .importPicture(_forest);

      expect(ok, isFalse);
      expect(c.read(appBackgroundControllerProvider).hasImage, isFalse);
      expect(await store.read(), isNull);
    });

    test(
      'bytes that are not a picture are refused and nothing is kept',
      () async {
        final store = MemoryBackgroundImageStore();
        final c = _container(store);
        final ok = await c
            .read(appBackgroundControllerProvider.notifier)
            .importPicture(Uint8List.fromList([1, 2, 3, 4]));
        expect(ok, isFalse);
        expect(c.read(appBackgroundControllerProvider).hasImage, isFalse);
        expect(await store.read(), isNull);
      },
    );

    test(
      'settings and range survive a restart, and none clears them',
      () async {
        final store = MemoryBackgroundImageStore();
        final first = _container(store);
        final notifier = first.read(appBackgroundControllerProvider.notifier);
        await notifier.importPicture(_forest);
        await notifier.setDim(0.8);
        await notifier.setVignette(false);
        await notifier.setBlur(0.5);
        final range = first.read(appBackgroundControllerProvider).range;

        final second = _container(store);
        await second.read(appBackgroundControllerProvider.notifier).restore();
        final s = second.read(appBackgroundControllerProvider);
        expect(
          (s.hasImage, s.dim, s.vignette, s.blur),
          (true, 0.8, false, 0.5),
        );
        expect(s.range.lightest, range.lightest);

        await second.read(appBackgroundControllerProvider.notifier).remove();
        expect(await store.read(), isNull);
        final third = _container(store);
        await third.read(appBackgroundControllerProvider.notifier).restore();
        expect(third.read(appBackgroundControllerProvider).hasImage, isFalse);
      },
    );

    test('a fresh install has no picture, a strong dim and vignette on', () {
      final c = _container(MemoryBackgroundImageStore());
      final s = c.read(appBackgroundControllerProvider);
      expect(
        (s.hasImage, s.dim, s.vignette),
        (false, kBackgroundDefaultDim, true),
      );
    });
  });

  group('host', () {
    testWidgets('panes stay opaque with no picture', (tester) async {
      final c = _container(MemoryBackgroundImageStore());
      await tester.pumpWidget(_host(c, const _Probe()));
      expect(find.text('1.00'), findsOneWidget);
      expect(find.byKey(const Key('app_background_layer')), findsNothing);
    });

    testWidgets('a picture paints one layer and makes panes translucent', (
      tester,
    ) async {
      final store = MemoryBackgroundImageStore();
      final c = _container(store);
      await tester.runAsync(
        () => c
            .read(appBackgroundControllerProvider.notifier)
            .importPicture(_forest),
      );
      await tester.runAsync(() => _decoded(c));
      await tester.pumpWidget(_host(c, const _Probe()));
      await tester.pump();
      expect(find.byKey(const Key('app_background_layer')), findsOneWidget);
      expect(
        find.text(kBackgroundPaneAlpha.toStringAsFixed(2)),
        findsOneWidget,
      );
    });

    testWidgets('high contrast puts the panes back to opaque', (tester) async {
      final store = MemoryBackgroundImageStore();
      final c = _container(store);
      await tester.runAsync(
        () => c
            .read(appBackgroundControllerProvider.notifier)
            .importPicture(_forest),
      );
      await tester.runAsync(() => _decoded(c));
      await tester.pumpWidget(_host(c, const _Probe()));
      await tester.pump();
      await tester.runAsync(
        () => c.read(highContrastControllerProvider.notifier).select(true),
      );
      await tester.pump();
      expect(find.byKey(const Key('app_background_layer')), findsNothing);
      expect(find.text('1.00'), findsOneWidget);
    });

    testWidgets('changing the dim does not rebuild the panes below', (
      tester,
    ) async {
      final c = _container(MemoryBackgroundImageStore());
      await tester.runAsync(
        () => c
            .read(appBackgroundControllerProvider.notifier)
            .importPicture(_forest),
      );
      await tester.runAsync(() => _decoded(c));
      final builds = <int>[];
      final probe = _Probe(builds);
      await tester.pumpWidget(_host(c, probe));
      await tester.pump();
      final before = builds.length;
      await tester.runAsync(() async {
        await c.read(appBackgroundControllerProvider.notifier).setDim(0.9);
        await c.read(appBackgroundControllerProvider.notifier).setBlur(0.4);
      });
      await tester.pump();
      expect(builds.length, before);
    });

    testWidgets('turning it on keeps the state of what is below', (
      tester,
    ) async {
      final c = _container(MemoryBackgroundImageStore());
      final builds = <int>[];
      await tester.pumpWidget(_host(c, _Probe(builds)));
      final id = builds.last;
      await tester.runAsync(
        () => c
            .read(appBackgroundControllerProvider.notifier)
            .importPicture(_forest),
      );
      await tester.runAsync(() => _decoded(c));
      await tester.pump();
      await tester.pump();
      expect(builds.last, id);
    });
  });
}
