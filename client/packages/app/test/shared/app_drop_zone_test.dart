// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The generic drop-target overlay: shown only while a drag is genuinely
/// over the target, and gone the moment it exits or the drop lands.
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
  required ValueChanged<List<DropItem>> onDrop,
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

void main() {
  testWidgets('the overlay is absent until a drag enters', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(_harness(enabled: true, onDrop: (_) {}));

    expect(find.text('Drop to attach'), findsNothing);

    _dropTarget(tester).onDragEntered!(_zeroEvent);
    await tester.pump();

    expect(find.text('Drop to attach'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the overlay disappears once the drag exits', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(_harness(enabled: true, onDrop: (_) {}));
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
      _harness(enabled: true, onDrop: (files) => dropped = files),
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
    await tester.pumpWidget(_harness(enabled: false, onDrop: (_) {}));
    expect(_dropTarget(tester).enable, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });
}
