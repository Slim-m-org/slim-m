// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Custom swatch: what it shows, what each choice sends, and that a
/// refusal stays on screen.
library;

import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/widgets/profile_fields_section.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/color_swatch_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _Harness {
  final patches = <Map<String, dynamic>>[];
  int? customRgb;
  bool refuse = false;
}

Future<_Harness> _pump(WidgetTester tester, {int? customRgb}) async {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = _Harness()..customRgb = customRgb;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            const json = {'content-type': 'application/json'};
            if (request.url.path != '/me') return http.Response('', 404);
            if (request.method == 'PATCH') {
              if (h.refuse) {
                return http.Response(
                  jsonEncode({'error': 'colour refused'}),
                  400,
                  headers: json,
                );
              }
              h.patches.add(jsonDecode(request.body) as Map<String, dynamic>);
            }
            return http.Response(
              jsonEncode({
                'id': 'self',
                'username': 'nc1107',
                'display_name': 'Nick',
                'created_at': 0,
                'permissions': 0,
                'profile_color': 0,
                'profile_color_rgb': h.customRgb,
              }),
              200,
              headers: json,
            );
          }),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: ProfileFieldsSection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> _saveHex(WidgetTester tester, String hex) async {
  await tester.tap(find.bySemanticsLabel('Profile colour: Custom'));
  await tester.pumpAndSettle();
  await tester.enterText(find.bySemanticsLabel('Hex colour'), hex);
  await tester.pump();
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a custom colour sends the rgb and the nearest preset', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _saveHex(tester, '#3366CC');
    expect(h.patches.single, {
      'profile_color': nearestColourIndex(
        const Color(0xFF3366CC),
        AppCanvasColors.cursors,
      ),
      'profile_color_rgb': 0x3366CC,
    });
  });

  testWidgets('a preset sends only the index, which clears the custom one', (
    tester,
  ) async {
    final h = await _pump(tester, customRgb: 0x3366CC);
    await tester.tap(find.bySemanticsLabel('Profile colour: Green'));
    await tester.pumpAndSettle();
    expect(h.patches.single, {'profile_color': 4});
  });

  testWidgets('Cancel in the picker sends nothing', (tester) async {
    final h = await _pump(tester);
    await tester.tap(find.bySemanticsLabel('Profile colour: Custom'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.patches, isEmpty);
  });

  testWidgets('a refused custom colour stays visible as an error', (
    tester,
  ) async {
    final h = await _pump(tester);
    h.refuse = true;
    await _saveHex(tester, '#3366CC');
    expect(find.textContaining('colour refused'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('with a custom colour set only Custom is selected', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, customRgb: 0x3366CC);
    bool selected(String name) =>
        tester
            .getSemantics(find.bySemanticsLabel('Profile colour: $name'))
            .flagsCollection
            .isSelected ==
        Tristate.isTrue;
    expect(selected('Custom'), isTrue);
    expect(selected('Pink'), isFalse);
    semantics.dispose();
  });

  testWidgets('the swatch row draws the custom slot after the presets', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ColorSwatchRow(
            label: 'Colour',
            colors: const [Color(0xFFFF0000)],
            names: const ['Red'],
            selected: null,
            onSelect: (_) {},
            custom: CustomSwatch(label: 'Custom', onTap: () => taps++),
          ),
        ),
      ),
    );
    final red = tester.getCenter(find.bySemanticsLabel('Colour: Red'));
    final custom = tester.getCenter(find.bySemanticsLabel('Colour: Custom'));
    expect(custom.dx, greaterThan(red.dx));
    await tester.tap(find.bySemanticsLabel('Colour: Custom'));
    expect(taps, 1);
  });
}
