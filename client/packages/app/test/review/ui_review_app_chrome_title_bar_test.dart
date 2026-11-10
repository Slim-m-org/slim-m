// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The frameless desktop title bar in each state it can be in, over the real
/// channel view, for the design review. Desktop only: a phone has no title bar.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_design_system/design_system.dart';

import '../desktop/support/fake_desktop_window_port.dart';
import '../ui_snapshot_support.dart';
import 'app_chrome_support.dart';

Future<void> _titleBar(
  WidgetTester tester, {
  String? state,
  FakeDesktopWindowPort? port,
  bool update = false,
  Future<void> Function(ChromeApp app)? afterSettle,
}) => captureChromeApp(
  tester,
  route: '/channels/c-general',
  viewport: 'desktop',
  surface: 'desktop-title-bar',
  state: state,
  overrides: desktopChromeOverrides(
    port: port,
    update: update ? reviewUpdate : null,
  ),
  afterSettle: afterSettle,
);

void main() {
  setUpAll(loadRealFonts);

  testWidgets('default', (tester) => _titleBar(tester));

  testWidgets('maximized', (tester) {
    final port = FakeDesktopWindowPort()..maximized = true;
    return _titleBar(tester, state: 'maximized', port: port);
  });

  // The bar paints nothing for focus, so this is expected to match the default.
  testWidgets('unfocused', (tester) {
    final port = FakeDesktopWindowPort();
    return _titleBar(
      tester,
      state: 'unfocused',
      port: port,
      afterSettle: (_) async => port.emit(DesktopWindowEventKind.blur),
    );
  });

  testWidgets(
    'update chip',
    (tester) => _titleBar(tester, state: 'update-chip', update: true),
  );

  testWidgets(
    'window menu',
    (tester) => _titleBar(
      tester,
      state: 'window-menu',
      update: true,
      afterSettle: (app) async {
        await app.tester.tap(find.byIcon(AppIcons.moreVertical).first);
        await app.tester.pump(const Duration(milliseconds: 350));
        expect(find.text('Quit slim-m'), findsOneWidget);
      },
    ),
  );
}
