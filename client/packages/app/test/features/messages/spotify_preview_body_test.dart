// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A Spotify link's card: its name, summary line and length, Spotify's mark,
/// a cover nothing is drawn over, and a Play button that opens the item off
/// the web engine.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/messages/providers/link_preview.dart';
import 'package:slimm_app/src/features/messages/providers/media_preferences.dart';
import 'package:slimm_app/src/features/messages/widgets/link_preview_card.dart';
import 'package:slimm_app/src/features/messages/widgets/link_preview_thumbnail.dart';
import 'package:slimm_app/src/features/messages/widgets/spotify_preview_body.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';

const _url = 'https://open.spotify.com/track/3ccGTp44b5m3TwTCrolFjw?si=x';
const _id = '3ccGTp44b5m3TwTCrolFjw';
const _removeLabel = 'Remove link preview';

const _track = LinkPreview(
  url: _url,
  title: 'Some Men Drown',
  description: 'Box Fan · Tell Me Nice Things · Song · 2026',
  siteName: 'Spotify',
  imageToken: 'cover',
  videoProvider: LinkPreviewVideoProvider.spotify,
  videoId: _id,
  mediaKind: SpotifyKind.track,
  durationMs: 336000,
);

Future<List<SpotifyEntity>> _pump(
  WidgetTester tester, {
  LinkPreview preview = _track,
  Size size = const Size(1280, 800),
  MediaAutoDownload? autoDownload,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final opened = <SpotifyEntity>[];
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith(
        (ref) => SharedPreferences.getInstance(),
      ),
      linkPreviewProvider(_url).overrideWith((ref) async => preview),
      linkPreviewImageBytesProvider(
        'cover',
      ).overrideWith((ref) async => Uint8List.fromList(const [1, 2, 3, 4])),
      spotifyItemOpenerProvider.overrideWithValue((item) async {
        opened.add(item);
        return true;
      }),
    ],
  );
  addTearDown(container.dispose);
  if (autoDownload != null) {
    await container
        .read(mediaAutoDownloadControllerProvider.notifier)
        .select(autoDownload);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: LinkPreviewCard(url: _url, onRemove: () {}),
          ),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
  return opened;
}

void main() {
  testWidgets('shows the name, summary line, length and Spotify mark', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Some Men Drown'), findsOneWidget);
    expect(
      find.text('Box Fan · Tell Me Nice Things · Song · 2026'),
      findsOneWidget,
    );
    expect(find.text('5:36'), findsOneWidget);
    expect(find.byKey(SpotifyPreviewBody.markKey), findsOneWidget);
    expect(find.text('Play on Spotify'), findsOneWidget);
    expect(find.text('Example News'), findsNothing);
  });

  for (final (label, size) in [
    ('desktop', const Size(1280, 800)),
    ('phone', const Size(390, 844)),
  ]) {
    testWidgets('on a $label nothing overlaps the cover', (tester) async {
      await _pump(tester, size: size);

      final art = tester.getRect(find.byKey(SpotifyPreviewBody.artKey));
      final play = tester.getRect(find.byKey(SpotifyPreviewBody.playKey));
      final remove = tester.getRect(find.byTooltip(_removeLabel));
      final mark = tester.getRect(find.byKey(SpotifyPreviewBody.markKey));
      expect(art.height, AppSpacing.s64 + AppSpacing.s16);
      expect(art.overlaps(play), isFalse);
      expect(art.overlaps(remove), isFalse);
      expect(play.overlaps(remove), isFalse);
      expect(mark.overlaps(remove), isFalse);
      expect(play.left, greaterThanOrEqualTo(art.right));
      expect(find.byIcon(AppIcons.play), findsOneWidget, reason: 'no glyph');
    });
  }

  testWidgets('Play and the card open the item off the web engine', (
    tester,
  ) async {
    final opened = await _pump(tester);
    final item = SpotifyEntity.tryCreate(SpotifyKind.track, _id)!;

    await tester.tap(find.byKey(SpotifyPreviewBody.playKey));
    await tester.pump();
    expect(opened, [item]);

    await tester.tap(find.text('Box Fan · Tell Me Nice Things · Song · 2026'));
    await tester.pump();
    expect(opened, [item, item]);
  });

  testWidgets('manual auto-download holds back only the cover', (tester) async {
    await _pump(tester, autoDownload: MediaAutoDownload.manual);

    expect(find.text('Some Men Drown'), findsOneWidget);
    expect(find.text('Play on Spotify'), findsOneWidget);
    final cover = find.descendant(
      of: find.byKey(SpotifyPreviewBody.artKey),
      matching: find.bySubtype<LinkPreviewThumbnail>(),
    );
    expect(cover, findsNothing);

    await tester.tap(find.bySemanticsLabel('Load the cover'));
    await pumpFrames(tester);
    expect(cover, findsOneWidget);
  });

  testWidgets('a playlist says what it is before its own description', (
    tester,
  ) async {
    await _pump(
      tester,
      preview: const LinkPreview(
        url: _url,
        title: 'Today’s Top Hits',
        description: 'The hottest 50. Cover: KAROL G',
        videoProvider: LinkPreviewVideoProvider.spotify,
        videoId: '37i9dQZF1DXcBWIGoYBM5M',
        mediaKind: SpotifyKind.playlist,
      ),
    );

    expect(
      find.text('Playlist · The hottest 50. Cover: KAROL G'),
      findsOneWidget,
    );
    expect(find.byKey(SpotifyPreviewBody.artKey), findsNothing);
  });

  testWidgets('a screen reader hears the whole title and summary', (
    tester,
  ) async {
    await _pump(tester);

    expect(
      find.bySemanticsLabel(
        'Open Some Men Drown on Spotify. '
        'Box Fan · Tell Me Nice Things · Song · 2026',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Play Some Men Drown on Spotify'),
      findsOneWidget,
    );
  });

  testWidgets('an item with no title is named by its kind aloud', (
    tester,
  ) async {
    await _pump(
      tester,
      preview: const LinkPreview(
        url: _url,
        description: 'Box Fan \u00b7 EP \u00b7 2026',
        videoProvider: LinkPreviewVideoProvider.spotify,
        videoId: _id,
        mediaKind: SpotifyKind.album,
      ),
    );

    expect(find.text('Spotify'), findsOneWidget, reason: 'only the header');
    expect(find.bySemanticsLabel('Play this album on Spotify'), findsOneWidget);
  });

  test('lengths read as m:ss, or h:mm:ss past an hour', () {
    expect(formatSpotifyDuration(336000), '5:36');
    expect(formatSpotifyDuration(59999), '0:59');
    expect(formatSpotifyDuration(10235000), '2:50:35');
    expect(formatSpotifyDuration(3600000), '1:00:00');
  });
}
