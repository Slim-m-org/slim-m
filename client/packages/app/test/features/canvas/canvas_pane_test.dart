// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas pane: it fetches on open, applies live frames for its own
/// channel and nobody else's, commits a drag, and says so when the server
/// refuses rather than rendering an empty board.
///
/// Its erase, undo and clear controls are a sibling suite,
/// `canvas_pane_ops_test.dart`, split out to stay under the file budget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_bar.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_header.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';
import '../../support/async_wait.dart';

void main() {
  testWidgets('opening the canvas fetches the region and paints it', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture()
      ..objects = [canvasObjectJson('a'), canvasObjectJson('b', x: 50)];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);

    await pumpCanvasPane(tester, container);
    expect(surfaceDocument(tester).objectCount.value, 2);
  });

  /// The gap the owner reported: an image placed by anyone but this exact
  /// session used to apply to the document (hit-testable, movable) and
  /// never paint, since only the paste path ever fetched its bytes back.
  testWidgets(
    'an image fetched from the viewport, not pasted by this client, ends '
    'up with a decoded bitmap',
    (tester) async {
      final fixture = CanvasPaneFixture()
        ..objects = [canvasImageJson('pic', authorId: 'someone-else')];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      // A real codec decode needs real asynchrony; pumpAndSettle alone never observes it, the same trap fullscreen_image_viewer_test.dart already documents.
      await tester.runAsync(() async {
        await pumpCanvasPane(tester, container);
      });
      await waitUntil(tester, () {
        final document = surfaceDocument(tester);
        final order = document.paintOrder;
        if (order.length != 1) return false;
        return document.strokeIfAlive(order.single)?.image != null;
      }, reason: 'the fetched image was never decoded');

      expect(fixture.attachmentFetches, 1);
      final document = surfaceDocument(tester);
      final slot = document.strokeIfAlive(document.paintOrder.single)!;
      expect(slot.image, isNotNull);
      expect(slot.imageLoadFailed, isFalse);
    },
  );

  testWidgets(
    'an image whose bytes cannot be fetched shows a load-failed placeholder',
    (tester) async {
      final fixture = CanvasPaneFixture(attachmentFetchStatus: 403)
        ..objects = [canvasImageJson('pic', authorId: 'someone-else')];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      final document = surfaceDocument(tester);
      final slot = document.strokeIfAlive(document.paintOrder.single)!;
      expect(slot.image, isNull);
      expect(slot.imageLoadFailed, isTrue);
    },
  );

  testWidgets(
    'a live-event image placement is hydrated the same as a fetched one',
    (tester) async {
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);

      fixture.events.add(
        api.CanvasObjectPlaced(
          channelId: 'c1',
          object: api.CanvasObject.fromJson(
            canvasImageJson('pic', authorId: 'someone-else'),
          ),
        ),
      );
      // Wait for the decoded image, not for a delay guessed on this machine.
      await waitUntil(tester, () {
        final document = surfaceDocument(tester);
        final order = document.paintOrder;
        if (order.length != 1) return false;
        return document.strokeIfAlive(order.single)?.image != null;
      }, reason: 'the live-event image placement was never hydrated');

      expect(fixture.attachmentFetches, 1);
      final document = surfaceDocument(tester);
      final slot = document.strokeIfAlive(document.paintOrder.single)!;
      expect(slot.image, isNotNull);
    },
  );

  testWidgets('a live frame for this channel lands, one for another does not', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);

    final document = surfaceDocument(tester);
    expect(document.objectCount.value, 0);

    fixture.events
      ..add(
        api.CanvasObjectPlaced(
          channelId: 'other',
          object: api.CanvasObject.fromJson(canvasObjectJson('elsewhere')),
        ),
      )
      ..add(
        api.CanvasObjectPlaced(
          channelId: 'c1',
          object: api.CanvasObject.fromJson(canvasObjectJson('here')),
        ),
      );
    await tester.pump();
    await tester.pump();

    expect(document.objectCount.value, 1);
    expect(document.knows('here'), isTrue);
    expect(document.knows('elsewhere'), isFalse);
  });

  testWidgets('a drag commits a stroke to the server', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);

    final gesture = await tester.startGesture(const Offset(100, 100));
    await gesture.moveTo(const Offset(160, 140));
    await gesture.moveTo(const Offset(220, 200));
    await gesture.up();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(fixture.posted, hasLength(1));
    expect(fixture.posted.single['kind'], 'stroke');
    expect(surfaceDocument(tester).objectCount.value, 1);
  });

  /// The server is the authority on whether this channel has a canvas at all,
  /// and a denial must read as a denial rather than as an empty board.
  testWidgets('a forbidden read says so instead of showing a blank canvas', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture(viewportStatus: 403);
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorState), findsOneWidget);
    expect(
      find.text('The canvas is not available in this channel.'),
      findsOneWidget,
    );
    expect(
      tester.widget<AppErrorState>(find.byType(AppErrorState)).onRetry,
      isNull,
      reason: 'a permission denial would just fail the same way again',
    );
  });

  /// canvas.md: an almost-certainly-transient failure left closing and
  /// reopening the pane as the only way forward, with nothing on screen
  /// saying so.
  testWidgets('a generic load failure offers Retry, which re-fetches', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture(viewportStatus: 500);
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    expect(find.text('The canvas could not be loaded.'), findsOneWidget);
    final before = fixture.viewportGets;

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(
      fixture.viewportGets,
      greaterThan(before),
      reason: 'Retry must re-run the same fetch, not just clear the banner',
    );
  });

  /// Silently dropping objects is what the strategy forbids: a truncated page
  /// has to say it was truncated.
  testWidgets('a truncated page renders a callout', (tester) async {
    final fixture = CanvasPaneFixture(hasMore: true)
      ..objects = [canvasObjectJson('a')];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    expect(find.byType(AppCallout), findsOneWidget);
  });

  /// Opening the canvas used to fire three requests: one against the
  /// degenerate viewport `initState` fetched before layout, and two more
  /// racing a stale read of `_fetched` inside the fetch's own repaint.
  testWidgets(
    'opening the canvas reads the view once, then the rest of the board once',
    (tester) async {
      final fixture = CanvasPaneFixture()..objects = [canvasObjectJson('a')];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);

      await pumpCanvasPane(tester, container);
      // Long enough for a wrongly-scheduled debounce to fire, so this cannot pass merely because the clock never advanced far enough to expose one.
      await tester.pump(const Duration(seconds: 1));

      expect(
        fixture.viewportGets,
        2,
        reason: 'the view, then one page of the board',
      );
    },
  );

  /// The unbounded loop: a truncated page resets `_fetched` to null, and
  /// reading that stale null from inside the fetch's own repaint rescheduled
  /// another fetch for the same, unmoved viewport every 150ms - forever,
  /// since a still-truncated answer can never make `_fetched` non-null.
  testWidgets(
    'a truncated region does not refetch on its own once the camera settles',
    (tester) async {
      final fixture = CanvasPaneFixture(hasMore: true)
        ..objects = [canvasObjectJson('a')];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);

      await pumpCanvasPane(tester, container);
      // One legitimate follow-up settles here: the truncated callout appearing shrinks CanvasSurface's own viewport, a real (if minor) size change that alone earns one refetch.
      await tester.pump(const Duration(seconds: 1));
      final settled = fixture.viewportGets;

      // Long enough that the old 150ms self-reschedule would have fired a dozen further times with the camera never moving again.
      await tester.pump(const Duration(seconds: 2));
      expect(fixture.viewportGets, settled);

      // A live frame also reaches refresh() and must not restart the loop.
      fixture.events.add(
        api.CanvasObjectPlaced(
          channelId: 'c1',
          object: api.CanvasObject.fromJson(canvasObjectJson('live')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(fixture.viewportGets, settled);
    },
  );

  /// `CanvasSurface` itself only ever draws whatever `elevationShadow` it is
  /// handed - see `canvas_painters_test.dart` for that half. This is the
  /// wiring half: the app layer must actually pass its own `AppShadows.float`
  /// through, or an elevated image would silently draw no shadow at all.
  testWidgets('the pane wires its own float shadow into the surface', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    final surface = tester.widget<CanvasSurface>(find.byType(CanvasSurface));
    expect(surface.elevationShadow, AppShadows.float);
  });

  /// The reachability guard. The canvas has no route, so nothing generic can
  /// see it: this is what fails if the header's affordance is ever dropped and
  /// the feature quietly becomes unreachable again. A voice channel's header,
  /// since that is the only kind that carries the button now.
  testWidgets('a voice channel header opens the canvas', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const Scaffold(
            body: ChannelHeader(
              channelId: 'c1',
              name: 'general',
              isVoice: true,
              searchOpen: false,
              onToggleSearch: _noop,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(container.read(canvasOpenProvider), isNull);
    await tester.tap(find.bySemanticsLabel('Open canvas'));
    await tester.pump();
    expect(container.read(canvasOpenProvider), 'c1');
  });

  /// CanvasBar is the pane's only header (no AppBar sits above it), so
  /// nothing else consumes the notch for it; the floating dock is the
  /// pane's own bottom-most interactive content, so the same claim applies
  /// to the home indicator now that the dock, not the drawing surface's own
  /// edge, is what a thumb reaches last.
  testWidgets(
    'the bar and the floating dock clear the notch and home indicator',
    (tester) async {
      const topInset = 59.0;
      const bottomInset = 34.0;
      const dpr = 3.0;
      const viewHeight = 932.0;
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);

      tester.view.physicalSize = const Size(390 * dpr, viewHeight * dpr);
      tester.view.devicePixelRatio = dpr;
      tester.view.padding = const FakeViewPadding(
        top: topInset * dpr,
        bottom: bottomInset * dpr,
      );
      tester.view.viewPadding = const FakeViewPadding(
        top: topInset * dpr,
        bottom: bottomInset * dpr,
      );
      addTearDown(tester.view.reset);

      await pumpCanvasPane(tester, container);

      expect(
        tester.getTopLeft(find.byType(CanvasBar)).dy,
        greaterThanOrEqualTo(topInset),
        reason: 'the bar painted under the status bar before this',
      );
      expect(
        tester.getBottomLeft(find.byType(FloatingDockCard)).dy,
        lessThanOrEqualTo(viewHeight - bottomInset),
        reason: 'the dock could paint under the home indicator otherwise',
      );
    },
  );
}

void _noop() {}
