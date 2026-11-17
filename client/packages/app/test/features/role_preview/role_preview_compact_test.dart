// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// At phone width the preview is one pane at a time: the rail, then a channel's summary with a
/// back action. A refused preview says so in place, with a retry, and keeps the banner's Exit.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/role_preview/providers/role_preview_controller.dart';
import 'package:slimm_app/src/features/role_preview/screens/role_preview_shell.dart';
import 'package:slimm_app/src/features/role_preview/widgets/role_preview_banner.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import 'role_preview_fixture.dart';

void main() {
  testWidgets('a phone drills from the rail into a summary and back', (
    tester,
  ) async {
    final (:container, :db) = await pumpPreviewShell(tester, width: 390);
    await enterPreview(tester, container);
    expect(find.text(RolePreviewShell.pickPrompt), findsNothing);

    await tester.tap(find.text('cs-chat'));
    await pumpFrames(tester);
    expect(find.text('What cs can do here'), findsOneWidget);
    expect(find.text('general'), findsNothing);
    expect(
      find.byKey(RolePreviewBanner.exitKey),
      findsOneWidget,
      reason: 'the banner stays over the summary',
    );

    await tester.tap(find.bySemanticsLabel('Back to channels'));
    await pumpFrames(tester);
    expect(find.text('general'), findsOneWidget);
    expect(find.text('What cs can do here'), findsNothing);
    await teardownPreviewShell(tester, container, db);
  });

  testWidgets(
    'a refused preview shows the reason with a retry, and Exit still leaves',
    (tester) async {
      final (:container, :db) = await pumpPreviewShell(
        tester,
        handler: (_) async => http.Response(
          '{"error":"you can only manage roles below your highest role","code":"role_hierarchy"}',
          403,
          headers: const {'content-type': 'application/json'},
        ),
      );
      await enterPreview(tester, container);

      expect(find.textContaining('Could not open the preview'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byKey(const Key('role-preview-banner')), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is AppErrorState), findsOneWidget);

      await tester.tap(find.byKey(RolePreviewBanner.exitKey));
      await pumpFrames(tester);
      expect(container.read(rolePreviewProvider), isNull);
      await teardownPreviewShell(tester, container, db);
    },
  );
}
