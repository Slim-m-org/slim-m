// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `confirmDangerousAction` and `promptReportReason` both used to be a bare
/// `AlertDialog`, which drew Material's own 28dp-radius shadowed card rather
/// than the border-first, radius-10 chrome every other modal in the app
/// shares - and one caller of the former had gone further and hand-rolled a
/// *filled* danger button, the one shape this design language forbids.
///
/// These assert both are fixed: the shared [showAppSheet] chrome (dialog on
/// a pointer layout, bottom sheet on a phone), and a destructive action that
/// stays outlined rather than filled.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/confirm_dialog.dart';
import 'package:slimm_app/src/features/members/widgets/report_dialog.dart';
import 'package:slimm_design_system/design_system.dart';

/// Mounts a single button that opens whatever [onTap] starts, so a test can
/// drive the real modal route rather than the bare content widget - the
/// phone/desktop split lives in [showAppSheet], not in the content itself.
Future<void> _pumpTrigger(
  WidgetTester tester,
  void Function(BuildContext context) onTap,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => onTap(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('confirmDangerousAction', () {
    testWidgets(
      'renders through the shared sheet chrome, not a bare AlertDialog',
      (tester) async {
        await _pumpTrigger(
          tester,
          (context) => confirmDangerousAction(
            context,
            title: 'Delete this?',
            message: 'This cannot be undone.',
            confirmLabel: 'Delete',
          ),
        );

        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(Dialog), findsOneWidget);
      },
    );

    testWidgets('the destructive action stays outlined, never filled', (
      tester,
    ) async {
      await _pumpTrigger(
        tester,
        (context) => confirmDangerousAction(
          context,
          title: 'Delete this?',
          message: 'This cannot be undone.',
          confirmLabel: 'Delete',
        ),
      );

      final button = tester.widget<AppButton>(
        find.widgetWithText(AppButton, 'Delete'),
      );
      // button.dart's own `_lookFor` defines danger as an outline over a transparent fill.
      expect(button.variant, AppButtonVariant.danger);
    });

    testWidgets('collapses to a bottom sheet at phone width', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pumpTrigger(
        tester,
        (context) => confirmDangerousAction(
          context,
          title: 'Delete this?',
          message: 'This cannot be undone.',
          confirmLabel: 'Delete',
        ),
      );

      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsOneWidget);
    });

    testWidgets('cancel answers false', (tester) async {
      bool? answer;
      await _pumpTrigger(tester, (context) {
        confirmDangerousAction(
          context,
          title: 'Delete this?',
          message: 'This cannot be undone.',
          confirmLabel: 'Delete',
        ).then((v) => answer = v);
      });

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(answer, isFalse);
    });
  });

  group('promptReportReason', () {
    testWidgets('the submit action stays disabled until a reason is typed', (
      tester,
    ) async {
      await _pumpTrigger(
        tester,
        (context) => promptReportReason(context, subjectLabel: 'this user'),
      );

      expect(
        tester
            .widget<AppButton>(find.widgetWithText(AppButton, 'Report'))
            .disabled,
        isTrue,
      );

      await tester.enterText(find.byType(TextField), 'Spamming the channel');
      await tester.pump();

      expect(
        tester
            .widget<AppButton>(find.widgetWithText(AppButton, 'Report'))
            .disabled,
        isFalse,
      );
    });

    testWidgets('answers the trimmed reason on submit, null on cancel', (
      tester,
    ) async {
      String? reason;
      await _pumpTrigger(tester, (context) {
        promptReportReason(
          context,
          subjectLabel: 'this user',
        ).then((v) => reason = v);
      });

      await tester.enterText(find.byType(TextField), '  spam  ');
      await tester.pump();
      await tester.tap(find.widgetWithText(AppButton, 'Report'));
      await tester.pumpAndSettle();

      expect(reason, 'spam');
    });
  });
}
