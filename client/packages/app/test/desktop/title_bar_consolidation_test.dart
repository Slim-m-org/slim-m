// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The title bar's name line used to be the static literal `slim-m`,
/// whatever deployment was actually open. It now shows the Space's real
/// name and this build's own version, as a window title. The connection dot
/// and the Space menu belong to `RailHeader`, which renders on every
/// platform (0012's 2026-09-25 addendum), so this bar must not draw them.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/title_bar.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/space_connection_dot.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import 'support/fake_desktop_window_port.dart';
import '../support/fake_api.dart';

Future<void> _pump(
  WidgetTester tester, {
  http.Response? versionResponse,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        mockApiOverride((_) async => versionResponse ?? http.Response('', 404)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Column(
            children: [
              TitleBar(
                port: FakeDesktopWindowPort(),
                platform: DesktopPlatform.linux,
                onRequestClose: () async {},
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'slim-m',
      packageName: 'top.npcserver.slimm',
      version: '1.2.3',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets(
    'the Space name and this build\'s version replace the static label once '
    'the server answers',
    (tester) async {
      await _pump(
        tester,
        versionResponse: http.Response(
          jsonEncode({
            'name': 'My Deployment',
            'version': '0.9.0',
            'protocol': 1,
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );

      expect(find.text('My Deployment'), findsOneWidget);
      expect(find.textContaining('1.2.3'), findsOneWidget);
      expect(
        find.text('slim-m'),
        findsNothing,
        reason: 'the real name replaces the static fallback once known',
      );
    },
  );

  testWidgets('falls back to the literal slim-m before the server answers', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('slim-m'), findsOneWidget);
  });

  testWidgets('draws neither the connection dot nor the Space menu: the rail '
      'header owns both, so nothing is shown twice 40px apart', (tester) async {
    await _pump(tester);

    expect(find.byType(SpaceConnectionDot), findsNothing);
    expect(find.byIcon(AppIcons.chevronDown), findsNothing);
  });

  testWidgets('the window controls sit the same distance from the right edge no '
      'matter how long the Space name is', (tester) async {
    Future<double> gapToEdge(String name) async {
      await _pump(
        tester,
        versionResponse: http.Response(
          jsonEncode({'name': name, 'version': '0.9.0', 'protocol': 1}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final barRight = tester.getTopRight(find.byType(TitleBar)).dx;
      final closeRight = tester
          .getTopRight(find.byIcon(AppIcons.windowClose))
          .dx;
      return barRight - closeRight;
    }

    final shortGap = await gapToEdge('x');
    final longGap = await gapToEdge(
      'A Genuinely Long Deployment Name That Reaches Well Into The Bar',
    );

    // The regression: a second flex child split the leftover width, stranding the controls when the name was short.
    expect(
      longGap,
      closeTo(shortGap, 0.5),
      reason: 'the controls must stay flush right regardless of name length',
    );

    // Equal gaps would also hold if both were stranded mid-bar, as rereported.
    expect(
      shortGap,
      lessThan(AppSpacing.s24),
      reason: 'flush right means at the edge, not merely consistently inset',
    );
  });
}
