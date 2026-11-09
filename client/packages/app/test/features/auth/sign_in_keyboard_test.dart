// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Creating an account on a phone: the field being typed in stays above the
/// keyboard.
///
/// The keyboard is modelled as view insets, the way Android and iOS report it,
/// and raised in steps the way a real one arrives. Visibility is read from the
/// laid-out rect of the field, not from the widget tree.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/default_server.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

/// A 390x844 iPhone-class screen and the smallest Android phone still in use.
const _phones = {'390x844': Size(390, 844), '360x640': Size(360, 640)};

/// What a soft keyboard takes of a phone's height, with its suggestion strip.
const _keyboardShare = 0.42;

const _systemBars = {
  TargetPlatform.android: EdgeInsets.fromLTRB(0, 24, 0, 24),
  TargetPlatform.iOS: EdgeInsets.fromLTRB(0, 47, 0, 34),
};

const _steps = [0.25, 0.5, 0.75, 1.0];

typedef _Server = ({String label, Uri address, List<String> fields});

final _servers = <_Server>[
  (
    label: 'self-hosted',
    address: Uri.parse('https://chat.example.test'),
    fields: ['Username', 'Password'],
  ),
  (
    label: 'official',
    address: Uri.parse(officialServer),
    fields: ['Username', 'Password'],
  ),
];

EdgeInsets get _bars => _systemBars[defaultTargetPlatform]!;

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required Uri server,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0
    ..padding = FakeViewPadding(top: _bars.top, bottom: _bars.bottom)
    ..viewPadding = FakeViewPadding(top: _bars.top, bottom: _bars.bottom);
  addTearDown(tester.view.reset);

  final httpClient = MockClient(
    (request) async => http.Response(
      jsonEncode({
        'name': 'slim-m',
        'version': '0.126.0',
        'protocol': 1,
        'claimed': true,
        'invite_required': true,
        'push_enabled': false,
      }),
      200,
      headers: const {'content-type': 'application/json'},
    ),
  );
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      serverUrlProvider.overrideWith((ref) => server),
      assumeNewAccountProvider.overrideWith((ref) => true),
      probeApiProvider.overrideWithValue(
        (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: httpClient),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const SignInScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
}

Finder _input(String label) =>
    find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label);

/// Scrolls [field] up from the fold the way a thumb would, then taps it.
Future<void> _focus(WidgetTester tester, Finder field, Size screen) async {
  final fold = screen.height - _bars.bottom;
  for (var drags = 0; tester.getRect(field).bottom > fold; drags++) {
    expect(drags, lessThan(20), reason: 'the field never came into reach');
    await tester.dragFrom(screen.center(Offset.zero), const Offset(0, -80));
    await tester.pump(const Duration(seconds: 1));
  }
  await tester.tap(field);
  await tester.pump();
}

/// Raises the keyboard and returns where it starts.
Future<double> _raiseKeyboard(WidgetTester tester, Size screen) async {
  final height = screen.height * _keyboardShare;
  for (final step in _steps) {
    tester.view
      ..viewInsets = FakeViewPadding(bottom: height * step)
      ..padding = FakeViewPadding(top: _bars.top);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pump(const Duration(seconds: 1));
  return screen.height - height;
}

Future<void> _lowerKeyboard(WidgetTester tester) async {
  tester.view
    ..resetViewInsets()
    ..padding = FakeViewPadding(top: _bars.top, bottom: _bars.bottom);
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  const platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.iOS,
  });

  for (final MapEntry(key: name, value: size) in _phones.entries) {
    for (final server in _servers) {
      testWidgets(
        'at $name on the ${server.label} server, each field stays above the '
        'keyboard',
        variant: platforms,
        (tester) async {
          await _pump(tester, size: size, server: server.address);

          for (final field in server.fields) {
            await _focus(tester, _input(field), size);
            final keyboardTop = await _raiseKeyboard(tester, size);

            final rect = tester.getRect(_input(field));
            expect(
              rect.top,
              greaterThanOrEqualTo(_bars.top),
              reason: '$field starts under the status bar at ${rect.top}',
            );
            expect(
              rect.bottom,
              lessThanOrEqualTo(keyboardTop),
              reason:
                  '$field ends at ${rect.bottom}, keyboard starts at '
                  '$keyboardTop',
            );

            await _lowerKeyboard(tester);
          }
        },
      );
    }
  }
}
