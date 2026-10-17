// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two media performance preferences: each defaults to what the app has
/// always done for downloading (on sight) while gifs hold until hovered or
/// tapped, a choice persists and
/// restores, an unknown stored value degrades to the default, and only the
/// default names itself so in the picker.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/messages/providers/media_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWith(
          (ref) => SharedPreferences.getInstance(),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('auto-download', () {
    test('defaults to always, so it is opt-in', () {
      expect(
        container().read(mediaAutoDownloadControllerProvider),
        MediaAutoDownload.always,
      );
      expect(MediaAutoDownload.always.label, contains('(default)'));
      expect(MediaAutoDownload.manual.label, isNot(contains('(')));
    });

    test('selecting persists, and restore reads it back', () async {
      final c = container();
      await c
          .read(mediaAutoDownloadControllerProvider.notifier)
          .select(MediaAutoDownload.manual);
      expect(
        (await SharedPreferences.getInstance()).getString(mediaAutoDownloadKey),
        'manual',
      );

      final c2 = container();
      await c2.read(mediaAutoDownloadControllerProvider.notifier).restore();
      expect(
        c2.read(mediaAutoDownloadControllerProvider),
        MediaAutoDownload.manual,
      );
    });

    test('an unknown stored value degrades to the default', () async {
      SharedPreferences.setMockInitialValues({mediaAutoDownloadKey: 'wifi'});
      final c = container();
      await c.read(mediaAutoDownloadControllerProvider.notifier).restore();
      expect(
        c.read(mediaAutoDownloadControllerProvider),
        MediaAutoDownload.always,
      );
    });
  });

  group('gif autoplay', () {
    test('defaults to hover or tap, so autoplay is opt-in', () {
      expect(
        container().read(gifAutoplayControllerProvider),
        GifAutoplay.tapToPlay,
      );
      expect(GifAutoplay.tapToPlay.label, contains('(default)'));
      expect(GifAutoplay.autoplay.label, isNot(contains('(')));
    });

    test('selecting persists, and restore reads it back', () async {
      final c = container();
      await c
          .read(gifAutoplayControllerProvider.notifier)
          .select(GifAutoplay.autoplay);
      expect(
        (await SharedPreferences.getInstance()).getString(gifAutoplayKey),
        'autoplay',
      );

      final c2 = container();
      await c2.read(gifAutoplayControllerProvider.notifier).restore();
      expect(c2.read(gifAutoplayControllerProvider), GifAutoplay.autoplay);
    });

    test('an unknown stored value degrades to the default', () async {
      SharedPreferences.setMockInitialValues({gifAutoplayKey: 'sometimes'});
      final c = container();
      await c.read(gifAutoplayControllerProvider.notifier).restore();
      expect(c.read(gifAutoplayControllerProvider), GifAutoplay.tapToPlay);
    });
  });
}
