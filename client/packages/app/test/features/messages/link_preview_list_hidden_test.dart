// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member-level "hide link previews" choice empties the list under a
/// message without touching the link in its text.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/messages/providers/media_preferences.dart';
import 'package:slimm_app/src/features/messages/widgets/link_preview_card.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: LinkPreviewList(urls: ['https://example.com/a']),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  ProviderContainer container() {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWith(
          (ref) => SharedPreferences.getInstance(),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  testWidgets('previews show by default', (tester) async {
    await _pump(tester, container());

    expect(find.byType(LinkPreviewCard), findsOneWidget);
  });

  testWidgets('hiding them removes every card', (tester) async {
    final c = container();
    c.read(linkPreviewDisplayControllerProvider.notifier).state =
        LinkPreviewDisplay.hide;
    await _pump(tester, c);

    expect(find.byType(LinkPreviewCard), findsNothing);
  });
}
