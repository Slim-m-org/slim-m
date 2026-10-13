// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The link preview card: renders a fetched preview's text and image, and
/// renders nothing at all for a missing one - never an error surface - the
/// same rule attachments follow when a fetch or decode fails.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/link_preview.dart';
import 'package:slimm_app/src/providers/media_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/link_preview_card.dart';
import 'package:slimm_design_system/design_system.dart';

const _url = 'https://example.com/article';

ProviderContainer _container(List<Override> overrides) {
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
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: LinkPreviewCard(url: _url)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a resolved preview shows its site name, title and description', (
    tester,
  ) async {
    final container = _container([
      linkPreviewProvider(_url).overrideWith(
        (ref) async => const LinkPreview(
          url: _url,
          title: 'An interesting article',
          description: 'What it is about.',
          siteName: 'Example News',
        ),
      ),
    ]);
    await _pump(tester, container);

    expect(find.text('Example News'), findsOneWidget);
    expect(find.text('An interesting article'), findsOneWidget);
    expect(find.text('What it is about.'), findsOneWidget);
  });

  testWidgets('a recognized video preview shows its channel name', (
    tester,
  ) async {
    final container = _container([
      linkPreviewProvider(_url).overrideWith(
        (ref) async => const LinkPreview(
          url: _url,
          title: 'A talk',
          videoProvider: LinkPreviewVideoProvider.youtube,
          videoId: 'dQw4w9WgXcQ',
          authorName: 'A Channel',
          authorUrl: 'https://www.youtube.com/@achannel',
        ),
      ),
    ]);
    await _pump(tester, container);

    expect(find.text('A Channel'), findsOneWidget);
  });

  testWidgets('an ordinary preview with no author shows no author row', (
    tester,
  ) async {
    final container = _container([
      linkPreviewProvider(_url).overrideWith(
        (ref) async => const LinkPreview(
          url: _url,
          title: 'An article',
          siteName: 'Example News',
        ),
      ),
    ]);
    await _pump(tester, container);

    expect(find.byIcon(AppIcons.account), findsNothing);
  });

  testWidgets('a null preview (disabled or no unfurl) renders nothing', (
    tester,
  ) async {
    final container = _container([
      linkPreviewProvider(_url).overrideWith((ref) async => null),
    ]);
    await _pump(tester, container);

    expect(tester.takeException(), isNull);
    expect(find.text('Example News'), findsNothing);
    expect(find.byType(LinkPreviewCard), findsOneWidget);
  });

  testWidgets(
    'a preview with an image respects auto-download off until tapped',
    (tester) async {
      final bytes = Uint8List.fromList(const [1, 2, 3, 4]);
      final container = _container([
        linkPreviewProvider(_url).overrideWith(
          (ref) async => const LinkPreview(
            url: _url,
            title: 'An article',
            imageToken: 'tok1',
          ),
        ),
        linkPreviewImageBytesProvider(
          'tok1',
        ).overrideWith((ref) async => bytes),
      ]);
      await container
          .read(mediaAutoDownloadControllerProvider.notifier)
          .select(MediaAutoDownload.manual);

      await _pump(tester, container);

      expect(find.text('Tap to load preview'), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      await tester.tap(find.text('Tap to load preview'));
      await tester.pumpAndSettle();

      expect(find.text('Tap to load preview'), findsNothing);
      expect(find.byType(Image), findsOneWidget);
    },
  );

  testWidgets(
    'a recognized video preview shows a play control over its image',
    (tester) async {
      final bytes = Uint8List.fromList(const [1, 2, 3, 4]);
      final container = _container([
        linkPreviewProvider(_url).overrideWith(
          (ref) async => const LinkPreview(
            url: _url,
            title: 'A talk',
            imageToken: 'tok1',
            videoProvider: LinkPreviewVideoProvider.youtube,
            videoId: 'dQw4w9WgXcQ',
          ),
        ),
        linkPreviewImageBytesProvider(
          'tok1',
        ).overrideWith((ref) async => bytes),
      ]);
      await _pump(tester, container);

      expect(find.byIcon(AppIcons.play), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    },
  );

  testWidgets('an ordinary preview shows no play control', (tester) async {
    final bytes = Uint8List.fromList(const [1, 2, 3, 4]);
    final container = _container([
      linkPreviewProvider(_url).overrideWith(
        (ref) async => const LinkPreview(
          url: _url,
          title: 'An article',
          imageToken: 'tok1',
        ),
      ),
      linkPreviewImageBytesProvider('tok1').overrideWith((ref) async => bytes),
    ]);
    await _pump(tester, container);

    expect(find.byIcon(AppIcons.play), findsNothing);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('a video preview with no thumbnail still offers a play control', (
    tester,
  ) async {
    final container = _container([
      linkPreviewProvider(_url).overrideWith(
        (ref) async => const LinkPreview(
          url: _url,
          title: 'A talk with no thumbnail',
          videoProvider: LinkPreviewVideoProvider.youtube,
          videoId: 'dQw4w9WgXcQ',
        ),
      ),
    ]);
    await _pump(tester, container);

    expect(find.byIcon(AppIcons.play), findsOneWidget);
  });

  testWidgets(
    'tapping a video preview on web swaps its thumbnail for the inline player',
    (tester) async {
      // Off web the tap opens the browser via a platform channel this VM test lacks; see link_preview_card.dart's _handlePlayTap.
      if (!kIsWeb) return;
      final bytes = Uint8List.fromList(const [1, 2, 3, 4]);
      final container = _container([
        linkPreviewProvider(_url).overrideWith(
          (ref) async => const LinkPreview(
            url: _url,
            title: 'A talk',
            imageToken: 'tok1',
            videoProvider: LinkPreviewVideoProvider.youtube,
            videoId: 'dQw4w9WgXcQ',
          ),
        ),
        linkPreviewImageBytesProvider(
          'tok1',
        ).overrideWith((ref) async => bytes),
      ]);
      await _pump(tester, container);

      await tester.tap(find.byIcon(AppIcons.play));
      await tester.pumpAndSettle();

      expect(find.byIcon(AppIcons.play), findsNothing);
      expect(find.byType(HtmlElementView), findsOneWidget);
    },
  );

  testWidgets('a stale image token refetches the preview once', (tester) async {
    var previews = 0;
    final png = Uint8List.fromList(const [
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0,
      0,
      0,
      0x0D,
      0x49,
      0x48,
      0x44,
      0x52,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      1,
      8,
      6,
      0,
      0,
      0,
      0x1F,
      0x15,
      0xC4,
      0x89,
      0,
      0,
      0,
      0x0D,
      0x49,
      0x44,
      0x41,
      0x54,
      0x78,
      0x9C,
      0x63,
      0xF8,
      0x0F,
      0,
      0,
      0x01,
      0x01,
      0,
      0x05,
      0x18,
      0xD8,
      0x4E,
      0,
      0,
      0,
      0,
      0x49,
      0x45,
      0x4E,
      0x44,
      0xAE,
      0x42,
      0x60,
      0x82,
    ]);
    final container = _container([
      linkPreviewProvider(_url).overrideWith((ref) async {
        previews += 1;
        return LinkPreview(
          url: _url,
          title: 'An interesting article',
          imageToken: previews == 1 ? 'stale' : 'fresh',
        );
      }),
      linkPreviewImageBytesProvider('stale').overrideWith((ref) async => null),
      linkPreviewImageBytesProvider('fresh').overrideWith((ref) async => png),
    ]);
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(previews, 2, reason: 'one refetch for the stale token');
    await tester.pumpAndSettle();
    expect(previews, 2, reason: 'never a loop');
  });
}
