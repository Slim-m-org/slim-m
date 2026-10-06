// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Paging between a message's images once one is open fullscreen.
///
/// A message with five photos used to open exactly the one that was tapped,
/// with no way to reach the other four. The viewer takes the whole message's
/// images now, opens at the tapped one, and pages.
///
/// The asymmetry these tests pin: the tapped page was handed its bytes by the
/// row and must never show a loading state, while a sibling has never been
/// fetched and shows one until it arrives.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/attachment_bytes.dart';
import 'package:slimm_app/src/widgets/attachment_view.dart';
import 'package:slimm_app/src/widgets/fullscreen_image_page.dart';
import 'package:slimm_app/src/widgets/fullscreen_image_viewer.dart';
import 'package:slimm_design_system/design_system.dart';

/// A 64x64 solid PNG, big enough to have a tap target; the 1x1 fixture other
/// suites use lays out at its intrinsic size and a tap lands beside it.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkA'
  'AAgEsAtmMCMaywi+hcEKLNP1WgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE'
  'BAQEBAQEBAQEBAQEBAQEBAQELguFPsFaQDQP9QAAAABJRU5ErkJggg==',
);

const _images = [
  api.Attachment(
    id: 'a1',
    filename: 'first.png',
    contentType: 'image/png',
    size: 2048,
  ),
  api.Attachment(
    id: 'a2',
    filename: 'second.png',
    contentType: 'image/png',
    size: 2048,
  ),
  api.Attachment(
    id: 'a3',
    filename: 'third.png',
    contentType: 'image/png',
    size: 2048,
  ),
];

/// A pdf between the images, so the gallery has something to leave out.
const _pdf = api.Attachment(
  id: 'a4',
  filename: 'lease.pdf',
  contentType: 'application/pdf',
  size: 4096,
);

/// One attachment rendered the way `message_row.dart` renders it, handed the
/// message's images as its siblings.
///
/// Only the tapped attachment is mounted rather than the whole row: three
/// stacked inline images overflow the test viewport, and what these tests are
/// about is what the viewer does once it is open, not the row's layout.
Widget _row(
  api.Attachment tapped,
  List<api.Attachment> attachments,
  List<Override> overrides,
) {
  // The production rule, not a copy: filtering here would prove nothing.
  final images = openableImages(attachments);
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: AttachmentView(attachment: tapped, siblings: images),
          ),
        ),
      ),
    ),
  );
}

/// Opens the viewer on [tapped], letting both the row's codec and the
/// viewer's own run.
Future<void> _openAt(
  WidgetTester tester,
  api.Attachment tapped,
  List<api.Attachment> attachments,
  List<Override> overrides,
) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(_row(tapped, attachments, overrides));
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  await tester.pumpAndSettle();
  expect(tester.getSize(find.byType(Image).first).height, greaterThan(0));
  await tester.tap(find.byType(Image).first);
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pumpAndSettle();
}

Override _servesPng() =>
    attachmentBytesProvider.overrideWith((ref, id) async => _png);

void main() {
  testWidgets('the counter says which of how many, from the tapped one', (
    tester,
  ) async {
    await _openAt(tester, _images[1], _images, [_servesPng()]);

    expect(find.byType(FullscreenImageViewer), findsOneWidget);
    expect(find.text('2 of 3'), findsOneWidget);
    expect(find.text('second.png'), findsOneWidget);
  });

  testWidgets('a lone image gets no counter', (tester) async {
    await _openAt(tester, _images.first, [_images.first], [_servesPng()]);

    expect(find.byType(FullscreenImageViewer), findsOneWidget);
    expect(find.textContaining(' of '), findsNothing);
  });

  testWidgets('the arrow keys step through the message', (tester) async {
    await _openAt(tester, _images.first, _images, [_servesPng()]);
    expect(find.text('1 of 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      find.text('2 of 3'),
      findsOneWidget,
      reason: 'a desktop window has no swipe, so the arrows have to work',
    );
    expect(find.text('second.png'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('1 of 3'), findsOneWidget);
  });

  testWidgets('the arrows stop at the ends rather than wrapping', (
    tester,
  ) async {
    await _openAt(tester, _images.first, _images, [_servesPng()]);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
      find.text('1 of 3'),
      findsOneWidget,
      reason: 'wrapping to the last image from the first is disorienting',
    );
  });

  testWidgets('only displayable images are pages', (tester) async {
    await _openAt(
      tester,
      _images.first,
      [_images.first, _pdf, _images[1]],
      [_servesPng()],
    );

    expect(
      find.text('1 of 2'),
      findsOneWidget,
      reason: 'a pdf is not a page in a photo gallery',
    );
  });

  testWidgets('a sibling still fetching does not hold up the tapped page', (
    tester,
  ) async {
    // The tapped image resolves; every other fetch hangs forever.
    final mixed = attachmentBytesProvider.overrideWith(
      (ref, id) => id == _images.first.id
          ? Future.value(_png)
          : Completer<Uint8List>().future,
    );
    await _openAt(tester, _images.first, _images, [mixed]);

    expect(
      find.byType(FullscreenImagePage),
      findsOneWidget,
      reason:
          'the row already had these bytes, so the tapped page renders '
          'whatever its siblings are doing',
    );
    expect(find.text('1 of 3'), findsOneWidget);
    expect(
      find.byType(FullscreenLoadFailure),
      findsNothing,
      reason: 'a fetch still in flight is not a failure',
    );
  });

  testWidgets('a sibling whose bytes never arrive offers a retry', (
    tester,
  ) async {
    var attempts = 0;
    final failsSiblings = attachmentBytesProvider.overrideWith((ref, id) {
      if (id == _images.first.id) return Future.value(_png);
      attempts++;
      return Future<Uint8List>.error(StateError('no'));
    });
    await _openAt(tester, _images.first, _images, [failsSiblings]);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    expect(find.byType(FullscreenLoadFailure), findsOneWidget);
    final before = attempts;
    await tester.tap(find.byType(FullscreenLoadFailure));
    await tester.pumpAndSettle();
    expect(
      attempts,
      greaterThan(before),
      reason:
          'a failed fetch is exactly what a retry fixes, unlike a failed '
          'decode',
    );
  });

  testWidgets(
    'opening the viewer fetches no sibling the reader has not reached',
    (tester) async {
      final fetched = <String>[];
      final counting = attachmentBytesProvider.overrideWith((ref, id) async {
        fetched.add(id);
        return _png;
      });
      await _openAt(tester, _images.first, _images, [counting]);

      expect(
        fetched,
        ['a1'],
        reason:
            'only the tapped image, fetched by the row before the viewer '
            'opened; an attachment can be megabytes and a reader who opens one '
            'image must not pay for the two beside it',
      );
    },
  );

  testWidgets('paging to a sibling is what fetches it', (tester) async {
    final fetched = <String>[];
    final counting = attachmentBytesProvider.overrideWith((ref, id) async {
      fetched.add(id);
      return _png;
    });
    await _openAt(tester, _images.first, _images, [counting]);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    expect(
      fetched,
      containsAll(<String>['a1', 'a2']),
      reason: 'the page the reader actually reached does load',
    );
    expect(
      fetched,
      isNot(contains('a3')),
      reason: 'and only that one - lazily still means lazily',
    );
  });

  testWidgets('the tapped page is the tapped one, not merely the first', (
    tester,
  ) async {
    await _openAt(tester, _images[1], _images, [_servesPng()]);

    final page = tester.widget<FullscreenImagePage>(
      find.byType(FullscreenImagePage),
    );
    expect(page.filename, 'second.png');
    expect(
      page.heroTag,
      isNotNull,
      reason:
          'only the bytes-in-hand branch carries the hero tag, so a null '
          'one here means the tapped page went through the fetch provider - '
          'which is the spinner this viewer promises never to show',
    );
  });

  testWidgets('a horizontal drag pages when not zoomed, and pans when zoomed', (
    tester,
  ) async {
    await _openAt(tester, _images[1], _images, [_servesPng()]);
    final viewer = find.byType(InteractiveViewer).hitTestable();

    final centre = tester.getCenter(viewer);
    final left = await tester.startGesture(centre - const Offset(20, 0));
    final right = await tester.startGesture(centre + const Offset(20, 0));
    await tester.pump();
    await left.moveBy(const Offset(-80, 0));
    await right.moveBy(const Offset(80, 0));
    await tester.pump();
    await left.up();
    await right.up();
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!
          .value
          .getMaxScaleOnAxis(),
      greaterThan(1.0),
      reason: 'the pinch must have zoomed or this proves nothing',
    );

    await tester.fling(viewer, const Offset(-300, 0), 1500);
    await tester.pumpAndSettle();
    expect(find.text('2 of 3'), findsOneWidget, reason: 'zoomed, so a pan');
  });

  testWidgets('a horizontal drag turns the page when not zoomed', (
    tester,
  ) async {
    await _openAt(tester, _images[1], _images, [_servesPng()]);

    await tester.fling(
      find.byType(InteractiveViewer).hitTestable(),
      const Offset(-300, 0),
      1500,
    );
    await tester.pumpAndSettle();

    expect(find.text('3 of 3'), findsOneWidget);
  });
}
