// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// First-run text that must survive a large text scale and a narrow screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/notification_schedule_controller.dart';
import 'package:slimm_app/src/screens/onboarding_dialogs.dart';
import 'package:slimm_app/src/screens/sign_in_alternatives.dart';
import 'package:slimm_app/src/widgets/member_notify_off_hours_item.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _frame(Widget child, {double scale = 1, double width = 360}) =>
    ProviderScope(
      overrides: [
        notificationScheduleProvider.overrideWith((ref) async => null),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

bool _exceeded(WidgetTester tester, Finder text) =>
    tester.renderObject<RenderParagraph>(text).didExceedMaxLines;

void main() {
  testWidgets('the sign-in alternatives wrap at 200% instead of ellipsizing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _frame(
        SignInAlternatives(
          creatingAccount: false,
          busy: false,
          onToggleCreating: () {},
          onUseDifferentSpace: () {},
        ),
        scale: 2,
      ),
    );
    final label = find.text('Create an account instead');
    expect(
      tester.renderObject<RenderParagraph>(label).size.height,
      greaterThan(
        tester.renderObject<RenderParagraph>(label).text.style!.fontSize! * 2.5,
      ),
      reason: 'two lines, not one clipped line',
    );
    expect(_exceeded(tester, label), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a single-line field grows with the text instead of clipping', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'http://localhost:8080');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _frame(AppInput(controller: controller, mono: true), scale: 2),
    );
    final field = tester.getRect(find.byType(AppInput));
    final text = tester.getRect(find.byType(EditableText));
    expect(field.height, greaterThanOrEqualTo(text.height));
    expect(field.contains(text.topLeft), isTrue);
    expect(field.contains(text.bottomRight), isTrue);
  });

  testWidgets('the redeem dialog sets its server address in mono', (
    tester,
  ) async {
    await tester.pumpWidget(_frame(const InviteDialog(), width: 420));
    final style = tester.widget<TextField>(find.byType(TextField).first).style;
    expect(style!.fontFamily, AppFonts.mono);
  });

  testWidgets('the member notify row fits a phone-width popover on one line', (
    tester,
  ) async {
    await tester.pumpWidget(
      _frame(
        MemberNotifyOffHoursItem(
          host: tester.binding.rootElement!,
          profile: api.UserProfile(
            id: 'u',
            username: 'u',
            displayName: 'u',
            createdAt: 0,
            roles: const [],
            isBot: false,
          ),
          run: (_) {},
        ),
        // The test font is wider than the shipped one, so this is a tight bound.
        width: 320,
      ),
    );
    await tester.pump();
    final label = find.text('Notify me off hours');
    expect(label, findsOneWidget);
    expect(_exceeded(tester, label), isFalse);
  });
}
