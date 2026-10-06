// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The slow-mode and join-muted controls after a failed save: they fall back to
/// the last value the server confirmed, show the error, and never render an
/// unlisted slow-mode value as Off.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/screens/channel_settings_join_muted_section.dart';
import 'package:slimm_app/src/screens/channel_settings_slow_mode_section.dart';
import 'package:slimm_design_system/design_system.dart';

import 'channel_management_harness.dart';

const _json = {'content-type': 'application/json'};

/// Answers a PATCH with the channel as the server would hold it, or a 500 when [fail] says so.
http.Response Function(http.Request) _server({
  required bool Function(Map<String, dynamic> body) fail,
  String kind = 'text',
}) {
  return (request) {
    if (request.method != 'PATCH') return http.Response('{}', 200);
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (fail(body)) {
      return http.Response(jsonEncode({'error': 'boom'}), 500, headers: _json);
    }
    return http.Response(
      jsonEncode({
        'id': 'c1',
        'name': 'general',
        'kind': kind,
        'created_at': 0,
        'slow_mode_seconds': body['slow_mode_seconds'] ?? 0,
        'join_muted': body['join_muted'] ?? false,
      }),
      200,
      headers: _json,
    );
  };
}

AppSegmentedControl _control(WidgetTester tester) =>
    tester.widget<AppSegmentedControl>(find.byType(AppSegmentedControl));

String _selectedLabel(WidgetTester tester) {
  final control = _control(tester);
  return control.options[control.selectedIndex].label;
}

Future<void> _pumpSlowMode(
  WidgetTester tester,
  int seconds,
  http.Response Function(http.Request) handler,
) async {
  await tester.pumpWidget(
    harness(
      ChannelSlowModeSection(
        channel: channel('c1', 'general').copyWith(slowModeSeconds: seconds),
      ),
      handler: handler,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('slow mode: a failed change falls back to the last saved value', (
    tester,
  ) async {
    await _pumpSlowMode(
      tester,
      0,
      _server(fail: (b) => b['slow_mode_seconds'] == 600),
    );

    await tester.tap(find.text('30s'));
    await tester.pumpAndSettle();
    expect(_selectedLabel(tester), '30s');

    await tester.tap(find.text('10m'));
    await tester.pumpAndSettle();

    expect(_selectedLabel(tester), '30s', reason: 'the server still holds 30s');
    expect(find.byType(AppErrorState), findsOneWidget);
  });

  testWidgets(
    'slow mode: a failed first change goes back to the opening value',
    (tester) async {
      await _pumpSlowMode(tester, 60, _server(fail: (_) => true));

      await tester.tap(find.text('10s'));
      await tester.pumpAndSettle();

      expect(_selectedLabel(tester), '1m');
      expect(find.byType(AppErrorState), findsOneWidget);
    },
  );

  testWidgets('slow mode: an unlisted value gets its own selected segment', (
    tester,
  ) async {
    await _pumpSlowMode(tester, 5, _server(fail: (_) => false));

    expect(_selectedLabel(tester), '5s');
    expect(
      _control(tester).options.map((o) => o.label),
      containsAll(['Off', '10m']),
    );
  });

  testWidgets('slow mode: an hour-long value reads in hours, not Off', (
    tester,
  ) async {
    await _pumpSlowMode(tester, 3600, _server(fail: (_) => false));

    expect(_selectedLabel(tester), '1h');
  });

  testWidgets(
    'join muted: a failed change falls back to the last saved value',
    (tester) async {
      await tester.pumpWidget(
        harness(
          ChannelJoinMutedSection(
            channel: channel('c1', 'voice', kind: 'voice'),
          ),
          handler: _server(
            fail: (b) => b['join_muted'] == false,
            kind: 'voice',
          ),
        ),
      );
      await tester.pumpAndSettle();
      bool value() => tester.widget<AppToggle>(find.byType(AppToggle)).value;

      await tester.tap(find.byType(AppToggle));
      await tester.pumpAndSettle();
      expect(value(), isTrue);

      await tester.tap(find.byType(AppToggle));
      await tester.pumpAndSettle();

      expect(value(), isTrue, reason: 'the server still holds join muted on');
      expect(find.byType(AppErrorState), findsOneWidget);
    },
  );
}
