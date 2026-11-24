// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A link's host is shown from its end, where the registrable domain is.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/link_destination.dart';
import 'package:slimm_design_system/design_system.dart';

const _spoof =
    'https://accounts.google.com.session-verify-0000000000.example.net/';

void main() {
  test('a short host is shown whole', () {
    expect(elideHostAtFront('chat.example.com'), 'chat.example.com');
  });

  test('a long host loses its leading labels, never its ending', () {
    final shown = elideHostAtFront(
      'accounts.google.com.session-verify-0000000000.example.net',
    );
    expect(shown, startsWith('…'));
    expect(shown, endsWith('example.net'));
    expect(shown.length, lessThanOrEqualTo(28));
  });

  test('one enormous label keeps its last characters', () {
    final shown = elideHostAtFront('${'a' * 80}b.example');
    expect(shown, endsWith('b.example'));
    expect(shown.length, lessThanOrEqualTo(28));
  });

  testWidgets(
    'the caption shows the end of the host and the full url on hover',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: LinkDestination(url: _spoof)),
        ),
      );
      expect(find.textContaining('example.net'), findsOneWidget);
      expect(find.textContaining('accounts.google.com.session'), findsNothing);
      expect(find.byTooltip(_spoof), findsOneWidget);
    },
  );
}
