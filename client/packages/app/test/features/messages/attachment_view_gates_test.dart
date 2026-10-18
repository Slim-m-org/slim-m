// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two media-performance gates on an inline attachment: with auto-download
/// off nothing is fetched until the tap, and a gif - held by default - waits
/// under a play badge for a hover or a tap. Whatever the setting, a gif holds
/// its first frame while the window is unfocused, since an animation nobody
/// is looking at is pure cost.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/media_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_reveal.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_video_player.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_view.dart';
import 'package:slimm_design_system/design_system.dart';

const _png = api.Attachment(
  id: 'p1',
  filename: 'photo.png',
  contentType: 'image/png',
  size: 4,
);

const _gif = api.Attachment(
  id: 'g1',
  filename: 'loop.gif',
  contentType: 'image/gif',
  size: 43,
);

/// A real 1x1 transparent gif, so the held-frame decode settles to a still
/// image rather than a shimmering placeholder pumpAndSettle would wait on.
final _gifBytes = base64Decode(
  'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
);

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

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  api.Attachment attachment,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: AttachmentView(attachment: attachment)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Whether the play badge is visible: it keeps its space while hidden, so
/// presence in the tree says nothing and the Visibility flag is the answer.
bool _badgeShown(WidgetTester tester) => tester
    .widget<Visibility>(
      find.ancestor(
        of: find.byIcon(AppIcons.play),
        matching: find.byType(Visibility),
      ),
    )
    .visible;

void main() {
  testWidgets('auto-download off fetches nothing until the tap', (
    tester,
  ) async {
    var fetched = false;
    final container = _container([
      attachmentBytesProvider(_png.id).overrideWith((ref) async {
        fetched = true;
        return Uint8List.fromList(const [1, 2, 3, 4]);
      }),
      attachmentPreviewBytesProvider.overrideWith((ref, key) async {
        fetched = true;
        return Uint8List.fromList(const [1, 2, 3, 4]);
      }),
    ]);
    await container
        .read(mediaAutoDownloadControllerProvider.notifier)
        .select(MediaAutoDownload.manual);

    await _pump(tester, container, _png);

    expect(find.text('Tap to load'), findsOneWidget);
    expect(fetched, isFalse, reason: 'held for download until asked');

    await tester.tap(find.text('Tap to load'));
    await tester.pumpAndSettle();

    expect(fetched, isTrue, reason: 'the tap is what triggers the fetch');
    expect(find.text('Tap to load'), findsNothing);
  });

  testWidgets(
    'auto-download off holds a video too, since a player opens on mount '
    '(issue 1935)',
    (tester) async {
      const video = api.Attachment(
        id: 'v1',
        filename: 'clip.mp4',
        contentType: 'video/mp4',
        size: 2048,
      );
      final container = _container(const []);
      await container
          .read(mediaAutoDownloadControllerProvider.notifier)
          .select(MediaAutoDownload.manual);

      await _pump(tester, container, video);

      expect(find.text('Tap to load'), findsOneWidget);
      expect(find.byType(AttachmentVideoPlayer), findsNothing);
    },
  );

  testWidgets('by default a gif plays on sight, with no play badge', (
    tester,
  ) async {
    final container = _container([
      attachmentBytesProvider(_gif.id).overrideWith((ref) async => _gifBytes),
    ]);

    await _pump(tester, container, _gif);

    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(AppIcons.play), findsNothing);
  });

  testWidgets('set to hover or tap, a gif holds under a play badge until the '
      'tap', (tester) async {
    final container = _container([
      attachmentBytesProvider(_gif.id).overrideWith((ref) async => _gifBytes),
    ]);
    await container
        .read(gifAutoplayControllerProvider.notifier)
        .select(GifAutoplay.tapToPlay);

    await _pump(tester, container, _gif);

    // Downloaded (bytes resolved), but frozen under a play badge, not animating.
    expect(find.byIcon(AppIcons.play), findsOneWidget);
    expect(find.byType(Image), findsNothing);

    await tester.tap(find.byIcon(AppIcons.play));
    await tester.pumpAndSettle();

    // Revealed: the badge is gone and the animating Image is in the tree.
    expect(find.byIcon(AppIcons.play), findsNothing);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('a pointer resting on a held gif plays it, and leaving holds it '
      'again', (tester) async {
    final container = _container([
      attachmentBytesProvider(_gif.id).overrideWith((ref) async => _gifBytes),
    ]);
    await container
        .read(gifAutoplayControllerProvider.notifier)
        .select(GifAutoplay.tapToPlay);
    await _pump(tester, container, _gif);
    expect(find.byType(Image), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byIcon(AppIcons.play)));
    await tester.pumpAndSettle();

    expect(
      find.byType(Image),
      findsOneWidget,
      reason: 'hover is the pointer path to seeing it',
    );
    expect(
      _badgeShown(tester),
      isFalse,
      reason: 'the badge hides while it plays, keeping its space',
    );

    // Well clear of the tile, which starts at the body's top-left corner.
    await mouse.moveTo(const Offset(780, 580));
    await tester.pumpAndSettle();

    expect(
      find.byType(Image),
      findsNothing,
      reason: 'not revealed: it only played while pointed at',
    );
    expect(_badgeShown(tester), isTrue);
  });

  testWidgets('a gif set to always still holds while the window is unfocused', (
    tester,
  ) async {
    final container = _container([
      attachmentBytesProvider(_gif.id).overrideWith((ref) async => _gifBytes),
    ]);
    await container
        .read(gifAutoplayControllerProvider.notifier)
        .select(GifAutoplay.autoplay);
    final binding = TestWidgetsFlutterBinding.instance;
    addTearDown(
      () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
    );
    await _pump(tester, container, _gif);
    expect(find.byType(Image), findsOneWidget);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();

    expect(
      find.byType(Image),
      findsNothing,
      reason: 'unfocused: nobody is watching it loop',
    );
    expect(
      find.byType(AttachmentFirstFrame),
      findsOneWidget,
      reason: 'the first frame, not a blank',
    );
    expect(
      find.byIcon(AppIcons.play),
      findsNothing,
      reason: 'not a gate: nothing to tap',
    );

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(
      find.byType(Image),
      findsOneWidget,
      reason: 'focus back, animation back',
    );
  });
}
