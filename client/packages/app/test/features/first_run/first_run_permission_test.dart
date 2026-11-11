// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The notifications step on a phone: the OS permission comes first, and the
/// level choice only follows a grant.
library;

import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/push/providers/push_controller.dart';

import 'first_run_harness.dart';

const _phone = Size(390, 800);

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await settle(tester);
}

Future<FirstRunRig> _toNotifications(
  WidgetTester tester, {
  PushStatus status = PushStatus.noTokenYet,
  PushStatus? answer,
}) async {
  final rig = await pumpFirstRun(
    tester,
    size: _phone,
    pushStatus: status,
    pushAnswer: answer,
  );
  await _tap(tester, 'Continue');
  await _tap(tester, 'Continue');
  return rig;
}

void main() {
  testWidgets('a phone is asked for the permission before any level', (
    tester,
  ) async {
    final rig = await _toNotifications(tester, answer: PushStatus.registered);
    expect(find.text('Turn on notifications'), findsOneWidget);
    expect(find.text('Notify me for'), findsNothing);
    expect(rig.push.registers, 0);

    await _tap(tester, 'Allow');
    expect(rig.push.registers, 1);
    expect(find.text('Choose your notifications'), findsOneWidget);
    expect(find.text('Notify me for'), findsOneWidget);

    await _tap(tester, 'Nothing');
    await _tap(tester, 'Continue');
    expect(rig.sent('PUT', '/push/preference'), hasLength(1));
    expect(find.text('Check your voice'), findsOneWidget);
  });

  testWidgets('declining skips the levels and moves on', (tester) async {
    final rig = await _toNotifications(tester);
    await _tap(tester, 'Not now');

    expect(rig.push.registers, 0);
    expect(find.text('Check your voice'), findsOneWidget);
    expect(find.text('Notify me for'), findsNothing);
    expect(rig.sent('PUT', '/push/preference'), isEmpty);
  });

  testWidgets('a refusal at the OS prompt skips the levels too', (
    tester,
  ) async {
    final rig = await _toNotifications(
      tester,
      answer: PushStatus.registeredNotificationsBlocked,
    );
    await _tap(tester, 'Allow');

    expect(rig.push.registers, 1);
    expect(find.text('Check your voice'), findsOneWidget);
  });

  testWidgets('a device already blocked never sees the step', (tester) async {
    final rig = await _toNotifications(
      tester,
      status: PushStatus.registeredNotificationsBlocked,
    );
    expect(find.text('Check your voice'), findsOneWidget);
    expect(rig.push.registers, 0);
  });

  testWidgets('back after declining asks again, not the levels', (
    tester,
  ) async {
    await _toNotifications(tester);
    await _tap(tester, 'Not now');
    await _tap(tester, 'Back');
    expect(find.text('Turn on notifications'), findsOneWidget);
  });

  testWidgets('the ask fits beside Back and Not now at phone width', (
    tester,
  ) async {
    await _toNotifications(tester);
    for (final label in ['Back', 'Not now', 'Allow']) {
      final rect = tester.getRect(find.text(label));
      expect(rect.left, greaterThanOrEqualTo(0), reason: label);
      expect(rect.right, lessThanOrEqualTo(_phone.width), reason: label);
    }
  });

  testWidgets('a skipped step is not counted in the progress', (tester) async {
    await _toNotifications(tester);
    expect(find.bySemanticsLabel('Step 3 of 4'), findsOneWidget);
    await _tap(tester, 'Not now');
    expect(find.bySemanticsLabel('Step 3 of 3'), findsOneWidget);
  });
}
