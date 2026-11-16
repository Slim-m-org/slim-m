// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The generic drop-target overlay: shown only while a drag is genuinely
/// over the target, and gone the moment it exits or the drop lands. Only the
/// zone a tap there would reach takes a drop and shows: one inside another,
/// not one clipped under a sibling, not one under a pushed page.
///
/// `desktop_drop`'s `DropTarget` has no platform implementation under
/// test, so these drive it the same way `flutter test`'s own widget probes
/// drive any third-party widget with no test double: found by type, its own
/// callbacks invoked directly, exactly as the real plugin would call them.
///
/// `debugDefaultTargetPlatformOverride` is set and cleared inside each test
/// body, never in `setUp`/`tearDown`: `TestWidgetsFlutterBinding` asserts
/// every debug var is back to null before the next test starts, and that
/// check runs before a `tearDown` callback would.
library;

import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/app_drop_zone.dart';
import 'package:slimm_design_system/design_system.dart';

DropTarget _dropTarget(WidgetTester tester) =>
    tester.widget<DropTarget>(find.byType(DropTarget));

final _zeroEvent = DropEventDetails(
  localPosition: Offset.zero,
  globalPosition: Offset.zero,
);

Widget _harness({
  required bool enabled,
  required void Function(List<DropItem> items, Offset at) onDrop,
}) => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(
    // Sized generously: a real caller wraps a channel pane or a settings card, never a bare line of text.
    body: SizedBox(
      width: 400,
      height: 400,
      child: AppDropZone(
        enabled: enabled,
        label: 'Drop to attach',
        icon: AppIcons.attachFile,
        onDrop: onDrop,
        child: const Center(child: Text('composer')),
      ),
    ),
  ),
);

/// Every target the plugin tells, offstage under another route or not.
final _everyTarget = find.byWidgetPredicate(
  (w) => w is DropTarget,
  skipOffstage: false,
);

/// Each enabled target whose box holds [global], as the plugin finds them, with its own local point.
Iterable<(DropTarget, Offset)> _targetsAt(
  WidgetTester tester,
  Offset global,
) sync* {
  for (final element in _everyTarget.evaluate()) {
    final target = element.widget as DropTarget;
    final box = element.renderObject! as RenderBox;
    final local = box.globalToLocal(global);
    if (target.enable && box.paintBounds.contains(local)) yield (target, local);
  }
}

/// A drop at [global], told to every target under it as the plugin tells them.
void _dropAt(WidgetTester tester, Offset global) {
  for (final (target, local) in _targetsAt(tester, global).toList()) {
    target.onDragDone!(
      DropDoneDetails(
        files: const [],
        localPosition: local,
        globalPosition: global,
      ),
    );
  }
}

/// A drag over [global]: every target under it hears it, and every other one hears it leave.
void _dragAt(WidgetTester tester, Offset global) {
  final under = _targetsAt(tester, global).map((t) => t.$1).toSet();
  for (final element in _everyTarget.evaluate()) {
    final target = element.widget as DropTarget;
    final details = DropEventDetails(
      localPosition: Offset.zero,
      globalPosition: global,
    );
    if (under.contains(target)) {
      target.onDragUpdated!(details);
    } else {
      target.onDragExited!(details);
    }
  }
}

/// A board-sized zone with a tile-sized zone inside it at (50, 50), each noting what lands on it.
Widget _nested({required bool tileTakesDrops, required List<String> landed}) =>
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 400,
            child: AppDropZone(
              enabled: true,
              label: 'Drop on the board',
              icon: AppIcons.image,
              onDrop: (_, at) => landed.add('board $at'),
              child: Stack(
                children: [
                  Positioned(
                    left: 50,
                    top: 50,
                    width: 100,
                    height: 100,
                    child: AppDropZone(
                      enabled: tileTakesDrops,
                      label: 'Drop on the tile',
                      icon: AppIcons.stamp,
                      onDrop: (_, at) => landed.add('tile $at'),
                      child: const Center(child: Text('tile')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

/// A 400 wide board docked beside a 200 wide chat, as a voice channel lays them out, with a
/// zoomed tile on the board whose box runs from x 300 to 500, under the chat.
Widget _besideChat(List<String> landed) => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 600,
        height: 400,
        child: Row(
          children: [
            Expanded(
              child: AppDropZone(
                enabled: true,
                label: 'Drop on the board',
                icon: AppIcons.image,
                onDrop: (_, _) => landed.add('board'),
                child: Stack(
                  children: [
                    Positioned(
                      left: 300,
                      top: 50,
                      width: 200,
                      height: 100,
                      child: ClipRect(
                        child: AppDropZone(
                          enabled: true,
                          label: 'Drop on the tile',
                          icon: AppIcons.stamp,
                          onDrop: (_, _) => landed.add('tile'),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: 200,
              child: AppDropZone(
                enabled: true,
                label: 'Drop to attach',
                icon: AppIcons.attachFile,
                onDrop: (_, _) => landed.add('chat'),
                child: const Center(child: Text('composer')),
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);

/// A call-sized zone under a pushed page that has a small zone of its own at (100, 100).
Widget _underPushedPage(
  GlobalKey<NavigatorState> navigator,
  List<String> landed,
) => MaterialApp(
  navigatorKey: navigator,
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(
    body: AppDropZone(
      enabled: true,
      label: 'Drop on the call',
      icon: AppIcons.stamp,
      onDrop: (_, _) => landed.add('call'),
      child: const SizedBox.expand(),
    ),
  ),
);

Route<void> _avatarPage(List<String> landed) => MaterialPageRoute<void>(
  builder: (_) => Scaffold(
    body: Stack(
      children: [
        Positioned(
          left: 100,
          top: 100,
          width: 100,
          height: 100,
          child: AppDropZone(
            enabled: true,
            label: 'Drop a new avatar',
            icon: AppIcons.image,
            onDrop: (_, _) => landed.add('avatar'),
            child: const SizedBox.expand(),
          ),
        ),
      ],
    ),
  ),
);

void main() {
  testWidgets('the overlay is absent until a drag enters', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(_harness(enabled: true, onDrop: (_, _) {}));

    expect(find.text('Drop to attach'), findsNothing);

    _dropTarget(tester).onDragEntered!(_zeroEvent);
    await tester.pump();

    expect(find.text('Drop to attach'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  double overlayOpacity(WidgetTester tester) => tester
      .widget<Opacity>(
        find
            .ancestor(
              of: find.text('Drop to attach'),
              matching: find.byWidgetPredicate((w) => w is Opacity),
            )
            .first,
      )
      .opacity;

  testWidgets('the overlay fades in rather than popping in', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(_harness(enabled: true, onDrop: (_, _) {}));

    _dropTarget(tester).onDragEntered!(_zeroEvent);
    await tester.pump();
    expect(overlayOpacity(tester), 0);

    await tester.pump(AppMotion.fast);
    expect(overlayOpacity(tester), 1);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('reduced motion shows the overlay at full strength at once', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(_harness(enabled: true, onDrop: (_, _) {}));

    _dropTarget(tester).onDragEntered!(_zeroEvent);
    await tester.pump();

    expect(overlayOpacity(tester), 1);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the overlay disappears once the drag exits', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(_harness(enabled: true, onDrop: (_, _) {}));
    final target = _dropTarget(tester);
    target.onDragEntered!(_zeroEvent);
    await tester.pump();
    expect(find.text('Drop to attach'), findsOneWidget);

    target.onDragExited!(_zeroEvent);
    await tester.pump();

    expect(find.text('Drop to attach'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a completed drop hides the overlay and reports the files', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    List<DropItem>? dropped;
    await tester.pumpWidget(
      _harness(enabled: true, onDrop: (files, _) => dropped = files),
    );
    final target = _dropTarget(tester);
    target.onDragEntered!(_zeroEvent);
    await tester.pump();

    final file = DropItemFile.fromData(Uint8List(0), path: 'holiday.png');
    target.onDragDone!(
      DropDoneDetails(
        files: [file],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    await tester.pump();

    expect(find.text('Drop to attach'), findsNothing);
    expect(dropped, [file]);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('disabled means the plugin is told not to listen at all', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(_harness(enabled: false, onDrop: (_, _) {}));
    expect(_dropTarget(tester).enable, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  Offset boardOrigin(WidgetTester tester) =>
      tester.getTopLeft(find.byWidgetPredicate((w) => w is DropTarget).first);

  testWidgets(
    'a zone inside another takes the drops on it, the outer the rest',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final landed = <String>[];
      await tester.pumpWidget(_nested(tileTakesDrops: true, landed: landed));
      final origin = boardOrigin(tester);

      _dropAt(tester, origin + const Offset(60, 70));
      _dropAt(tester, origin + const Offset(300, 250));

      expect(landed, [
        'tile ${const Offset(10, 20)}',
        'board ${const Offset(300, 250)}',
      ]);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('a disabled inner zone leaves its drops to the outer one', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final landed = <String>[];
    await tester.pumpWidget(_nested(tileTakesDrops: false, landed: landed));

    _dropAt(tester, boardOrigin(tester) + const Offset(60, 70));

    expect(landed, ['board ${const Offset(60, 70)}']);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a drag over the inner zone shows only its overlay', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(_nested(tileTakesDrops: true, landed: []));
    final origin = boardOrigin(tester);

    _dragAt(tester, origin + const Offset(100, 100));
    await tester.pump();
    final overTile = (
      find.text('Drop on the tile').evaluate().length,
      find.text('Drop on the board').evaluate().length,
    );
    _dragAt(tester, origin + const Offset(300, 300));
    await tester.pump();

    expect(overTile, (1, 0));
    expect(find.text('Drop on the tile'), findsNothing);
    expect(find.text('Drop on the board'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'a tile reaching under the chat beside it takes only what lands on the board',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final landed = <String>[];
      await tester.pumpWidget(_besideChat(landed));
      final origin = boardOrigin(tester);

      _dropAt(tester, origin + const Offset(450, 100));
      final underChat = [...landed];
      _dropAt(tester, origin + const Offset(350, 100));

      expect(underChat, ['chat'], reason: 'the chat covers the tile there');
      expect(landed, ['chat', 'tile']);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('a drag over the chat never shows the tile under it', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(_besideChat([]));

    _dragAt(tester, boardOrigin(tester) + const Offset(450, 100));
    await tester.pump();

    expect(find.text('Drop on the tile'), findsNothing);
    expect(find.text('Drop to attach'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a zone under a pushed page takes nothing dropped on that page', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final landed = <String>[];
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(_underPushedPage(navigator, landed));
    unawaited(navigator.currentState!.push(_avatarPage(landed)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    _dropAt(tester, const Offset(150, 150));
    _dropAt(tester, const Offset(300, 300));

    expect(landed, ['avatar']);
    debugDefaultTargetPlatformOverride = null;
  });
}
