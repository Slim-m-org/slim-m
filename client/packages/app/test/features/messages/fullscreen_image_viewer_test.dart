// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tapping an image opens it fullscreen, dismissing returns, and nothing
/// that is not a displayable image is tappable at all.
///
/// The bytes are handed to the viewer by the row that already has them, so
/// "still loading" and "failed" are asserted as states that cannot open the
/// viewer rather than as states the viewer renders.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_view.dart';
import 'package:slimm_app/src/features/messages/widgets/fullscreen_image_viewer.dart';
import 'package:slimm_app/src/features/messages/widgets/fullscreen_image_page.dart';
import 'package:slimm_design_system/design_system.dart';

/// A 64x64 solid PNG. Real bytes, so `Image.memory` decodes them, and big
/// enough to have a tap target: the 1x1 fixture the other suites use lays out
/// at its intrinsic size, which a tap lands beside rather than on.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkA'
  'AAgEsAtmMCMaywi+hcEKLNP1WgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE'
  'BAQEBAQEBAQEBAQEBAQEBAQELguFPsFaQDQP9QAAAABJRU5ErkJggg==',
);

const _image = api.Attachment(
  id: 'a1',
  filename: 'holiday.png',
  contentType: 'image/png',
  size: 2048,
);

const _pdf = api.Attachment(
  id: 'a2',
  filename: 'lease.pdf',
  contentType: 'application/pdf',
  size: 4096,
);

/// An `image/` type the server's allowlist does not hold, so it never serves
/// it inline and this client must not try to decode or open it either.
const _svg = api.Attachment(
  id: 'a3',
  filename: 'diagram.svg',
  contentType: 'image/svg+xml',
  size: 512,
);

Widget _app(api.Attachment attachment, List<Override> overrides) {
  return ProviderScope(
    overrides: [
      attachmentPreviewBytesProvider.overrideWith((ref, key) async => _png),
      ...overrides,
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: AttachmentView(attachment: attachment),
          ),
        ),
      ),
    ),
  );
}

Override _servesPng() =>
    attachmentBytesProvider.overrideWith((ref, id) async => _png);

Finder _viewer() => find.byType(FullscreenImageViewer);

Finder _closeButton() => find.byWidgetPredicate(
  (w) => w is AppIconButton && w.semanticLabel == 'Close image',
);

/// Pumps the row and lets the codec run. Decoding needs real asynchrony, and
/// an undecoded `Image` lays out at zero size, which a tap lands beside.
Future<void> _pumpDecoded(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(_app(_image, [_servesPng()]));
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  await tester.pumpAndSettle();
  expect(tester.getSize(find.byType(Image).first).height, greaterThan(0));
}

/// Opens the fullscreen viewer over the decoded row, then lets the viewer's
/// OWN codec run.
///
/// [_pumpDecoded] only waits for the row's image. The viewer that opens on
/// top renders a second `Image.memory`, and nothing used to wait for that
/// one - zero-sized, `InteractiveViewer`'s child gives a pinch nothing to
/// scale, so the transform stays at 1.0. That made the pinch case pass only
/// when an earlier test in this file had already warmed the codec.
Future<void> _openViewer(WidgetTester tester) async {
  await _pumpDecoded(tester);
  expect(_viewer(), findsNothing);
  await tester.tap(find.byType(Image).first);
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pumpAndSettle();
}

/// Two fingers moving apart across the open viewer.
Future<void> _pinchOpen(WidgetTester tester) async {
  final centre = tester.getCenter(find.byType(InteractiveViewer));
  final left = await tester.startGesture(centre - const Offset(20, 0));
  final right = await tester.startGesture(centre + const Offset(20, 0));
  await tester.pump();
  await left.moveBy(const Offset(-80, 0));
  await right.moveBy(const Offset(80, 0));
  await tester.pump();
  await left.up();
  await right.up();
  await tester.pumpAndSettle();
}

double _scale(WidgetTester tester) {
  final viewer = tester.widget<InteractiveViewer>(
    find.byType(InteractiveViewer),
  );
  return viewer.transformationController!.value.getMaxScaleOnAxis();
}

void main() {
  testWidgets(
    'the viewer opens on the inline preview and swaps to the original '
    'when it arrives',
    (tester) async {
      final original = Completer<Uint8List>();
      final full = Uint8List.fromList([..._png, 0]);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          _app(_image, [
            attachmentBytesProvider.overrideWith((ref, id) => original.future),
          ]),
        );
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Image).first);
      await tester.pumpAndSettle();

      FullscreenImagePage page() =>
          tester.widget<FullscreenImagePage>(find.byType(FullscreenImagePage));
      expect(page().bytes, _png, reason: 'no spinner while the original loads');

      original.complete(full);
      await tester.pumpAndSettle();

      expect(page().bytes, full);
    },
  );

  testWidgets('tapping an image opens it fullscreen and closing returns', (
    tester,
  ) async {
    await _openViewer(tester);

    expect(_viewer(), findsOneWidget);
    expect(find.text('holiday.png'), findsOneWidget);

    await tester.tap(_closeButton());
    await tester.pumpAndSettle();

    expect(_viewer(), findsNothing);
    expect(find.byType(AttachmentView), findsOneWidget);
  });

  testWidgets('the filename renders under a real Material ancestor', (
    tester,
  ) async {
    await _openViewer(tester);

    expect(
      find.ancestor(
        of: find.text('holiday.png'),
        matching: find.byType(Material),
      ),
      findsWidgets,
      reason:
          'without one, Flutter renders the filename in its own debug '
          'fallback style (red text, a double yellow underline), not the '
          'colour the theme actually asks for',
    );
  });

  testWidgets('swiping down dismisses the viewer', (tester) async {
    await _openViewer(tester);
    expect(_viewer(), findsOneWidget);

    // The default touch slop is the point: it makes the drag recognizer
    // claim the pointer before the viewer's pan does, as a real finger would.
    await tester.drag(find.byType(InteractiveViewer), const Offset(0, 240));
    await tester.pumpAndSettle();

    expect(_viewer(), findsNothing);
  });

  testWidgets('pinching zooms rather than dismissing', (tester) async {
    await _openViewer(tester);
    await _pinchOpen(tester);

    expect(_viewer(), findsOneWidget);
    expect(_scale(tester), greaterThan(1.0));
  });

  testWidgets('dragging while zoomed pans instead of dismissing', (
    tester,
  ) async {
    await _openViewer(tester);
    await _pinchOpen(tester);

    await tester.drag(find.byType(InteractiveViewer), const Offset(0, 240));
    await tester.pumpAndSettle();

    expect(_viewer(), findsOneWidget);
  });

  testWidgets('the viewer keeps its image inside the safe area', (
    tester,
  ) async {
    const padding = FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.viewPadding = padding;
    tester.view.padding = padding;
    addTearDown(tester.view.reset);

    await _openViewer(tester);

    final rect = tester.getRect(find.byType(InteractiveViewer));
    expect(rect.top, greaterThanOrEqualTo(59.0));
    expect(rect.bottom, lessThanOrEqualTo(844.0 - 34.0));
  });

  testWidgets('a non-image attachment does not open fullscreen', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_pdf, const []));
    await tester.pumpAndSettle();

    expect(isInlineImage(_pdf.contentType), isFalse);
    expect(find.text('lease.pdf'), findsOneWidget);

    await tester.tap(find.text('lease.pdf'));
    await tester.pumpAndSettle();

    expect(_viewer(), findsNothing);
  });

  testWidgets('an image type the server never serves inline stays a chip', (
    tester,
  ) async {
    expect(isInlineImage(_svg.contentType), isFalse);

    await tester.pumpWidget(_app(_svg, const []));
    await tester.pumpAndSettle();

    expect(find.text('diagram.svg'), findsOneWidget);
    expect(find.byType(Image), findsNothing);

    await tester.tap(find.text('diagram.svg'));
    await tester.pumpAndSettle();

    expect(_viewer(), findsNothing);
  });

  testWidgets('a still-loading image does not open fullscreen', (tester) async {
    final pending = Completer<Uint8List>();
    addTearDown(() => pending.complete(_png));

    await tester.pumpWidget(
      _app(_image, [
        attachmentBytesProvider.overrideWith((ref, id) => pending.future),
        attachmentPreviewBytesProvider.overrideWith(
          (ref, key) => pending.future,
        ),
      ]),
    );
    await tester.pump();

    await tester.tap(find.byType(AttachmentView));
    await tester.pump();

    expect(_viewer(), findsNothing);
  });

  testWidgets('a failed image retries instead of opening fullscreen', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      _app(_image, [
        attachmentPreviewBytesProvider.overrideWith((ref, key) {
          attempts++;
          return Future<Uint8List>.error(StateError('gone'));
        }),
      ]),
    );
    await tester.pumpAndSettle();
    expect(attempts, 1);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(_viewer(), findsNothing);
    expect(attempts, 2, reason: 'the tap retries the fetch');
  });

  testWidgets(
    'bytes that fetch but fail to decode open the viewer anyway, since '
    'AttachmentView offers no other tap target - it must show its own '
    'failure message rather than throw or blank the screen',
    (tester) async {
      await tester.pumpWidget(
        _app(_image, [
          attachmentPreviewBytesProvider.overrideWith(
            (ref, key) async => Uint8List.fromList(const [1, 2, 3, 4]),
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Could not open'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(_viewer(), findsOneWidget);
      expect(find.text('Could not open holiday.png.'), findsOneWidget);
    },
  );
}
