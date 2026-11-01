// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The admin setup: who is offered it and when, that it is offered once and
/// can be run again, and that each step writes through the settings route the
/// Space settings pane already uses.
library;

import 'dart:ui' show Size;

import 'package:flutter/material.dart' show Material;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/admin_setup/providers/admin_setup_controller.dart';
import 'package:slimm_app/src/features/admin_setup/screens/admin_setup_flow.dart';
import 'package:slimm_app/src/features/admin_setup/screens/admin_setup_steps.dart';

import 'package:slimm_design_system/design_system.dart' show AppToggle;

import 'admin_setup_harness.dart';

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await settleSetup(tester);
}

Future<void> _toStep(WidgetTester tester, int index) async {
  for (var i = 0; i < index; i++) {
    await _tap(tester, 'Continue');
  }
}

void main() {
  group('who is offered it', () {
    testWidgets('the admin who claimed the space sees this machine', (
      tester,
    ) async {
      await pumpAdminSetup(tester);
      expect(find.text('Your server'), findsOneWidget);
      expect(
        find.textContaining('about 340 to 770 people connected at once'),
        findsOneWidget,
      );
      expect(
        find.textContaining('8 cores, 16 GB memory, 400 GB free of 500 GB'),
        findsOneWidget,
      );
    });

    testWidgets('a member never sees it and never asks the server', (
      tester,
    ) async {
      final rig = await pumpAdminSetup(tester, permissions: 0);
      expect(find.text('shell'), findsOneWidget);
      expect(find.text('Skip setup'), findsNothing);
      expect(rig.sent('GET', '/space/setup'), isEmpty);
    });

    testWidgets('an admin who did not claim the space is not offered it', (
      tester,
    ) async {
      final rig = await pumpAdminSetup(
        tester,
        setup: SetupFacts(claimedByMe: false),
      );
      expect(rig.sent('GET', '/space/setup'), hasLength(1));
      expect(find.text('Skip setup'), findsNothing);
    });

    testWidgets('a finished setup is not offered again', (tester) async {
      await pumpAdminSetup(tester, setup: SetupFacts(completed: true));
      expect(find.text('Skip setup'), findsNothing);
      expect(find.text('shell'), findsOneWidget);
    });

    testWidgets('it waits for the member welcome to be done', (tester) async {
      await pumpAdminSetup(tester, accountAge: const Duration(minutes: 5));
      expect(find.text('Welcome'), findsOneWidget);
      expect(find.text('Your server'), findsNothing);

      await _tap(tester, 'Skip setup');

      expect(find.text('Welcome'), findsNothing);
      expect(find.text('Your server'), findsOneWidget);
    });
  });

  group('once, and again', () {
    testWidgets('skipping tells the server and closes it', (tester) async {
      final rig = await pumpAdminSetup(tester);
      await _tap(tester, 'Skip setup');

      expect(rig.sent('POST', '/space/setup/complete'), hasLength(1));
      expect(find.text('Your server'), findsNothing);
      expect(rig.facts.completed, isTrue);
    });

    testWidgets('finishing the last step tells the server', (tester) async {
      final rig = await pumpAdminSetup(tester);
      await _toStep(tester, AdminSetupStep.values.length - 1);
      expect(find.text('Voice defaults'), findsOneWidget);
      expect(rig.sent('POST', '/space/setup/complete'), isEmpty);

      await _tap(tester, 'Finish');

      expect(rig.sent('POST', '/space/setup/complete'), hasLength(1));
      expect(find.text('Voice defaults'), findsNothing);
    });

    testWidgets('a refused close keeps it open and says so', (tester) async {
      final rig = await pumpAdminSetup(
        tester,
        setup: SetupFacts(failComplete: true),
      );
      await _tap(tester, 'Skip setup');

      expect(find.textContaining('Not saved'), findsOneWidget);
      expect(find.text('Your server'), findsOneWidget);
      expect(rig.facts.completed, isFalse);
    });

    testWidgets('running it again opens it and saves nothing', (tester) async {
      final rig = await pumpAdminSetup(
        tester,
        setup: SetupFacts(completed: true),
      );
      rig.container.read(adminSetupControllerProvider.notifier).replay();
      await settleSetup(tester);
      expect(find.text('Your server'), findsOneWidget);

      await _tap(tester, 'Skip setup');

      expect(find.text('Your server'), findsNothing);
      expect(rig.sent('POST', '/space/setup/complete'), isEmpty);
    });

    testWidgets('back returns to the earlier step', (tester) async {
      await pumpAdminSetup(tester);
      await _tap(tester, 'Continue');
      expect(find.text('Name your Space'), findsOneWidget);
      await _tap(tester, 'Back');
      expect(find.text('Your server'), findsOneWidget);
    });
  });

  group('each step writes through the existing route', () {
    testWidgets('who can join patches the space settings', (tester) async {
      final rig = await pumpAdminSetup(tester);
      await _toStep(tester, 2);
      await _tap(tester, 'People with an invite');
      await _tap(tester, 'Anyone with the address');

      expect(rig.lastBody('PATCH', '/space/settings'), {'join_policy': 'open'});
    });

    testWidgets('uploads patches the media compression route', (tester) async {
      final rig = await pumpAdminSetup(tester);
      await _toStep(tester, 3);
      await tester.tap(find.byType(AppToggle).first);
      await settleSetup(tester);

      expect(rig.lastBody('PATCH', '/space/media-compression'), {
        'enabled': true,
      });
    });

    testWidgets('retention patches the retention route', (tester) async {
      final rig = await pumpAdminSetup(tester);
      await _toStep(tester, 4);
      await _tap(tester, '30 days');
      await _tap(tester, 'Set to 30 days');

      expect(rig.lastBody('PATCH', '/space/retention'), {'retention_days': 30});
    });

    testWidgets('voice patches the screen share route', (tester) async {
      final rig = await pumpAdminSetup(tester);
      await _toStep(tester, 5);
      await _tap(tester, '720p');

      expect(rig.lastBody('PATCH', '/space/screen-share'), {'max_height': 720});
    });
  });

  group('hardware recommendations', () {
    testWidgets('low disk points the uploads and retention steps at the fix', (
      tester,
    ) async {
      await pumpAdminSetup(
        tester,
        setup: SetupFacts(diskFree: 6 * gib, diskTotal: 100 * gib),
      );
      expect(find.text('Suggested for this server'), findsOneWidget);
      await _toStep(tester, 3);
      expect(
        find.textContaining('Photo compression keeps uploads small'),
        findsOneWidget,
      );
      await _tap(tester, 'Continue');
      expect(
        find.textContaining('A retention window deletes old'),
        findsOneWidget,
      );
    });

    testWidgets('few cores point the voice step at a lower screen share', (
      tester,
    ) async {
      await pumpAdminSetup(tester, setup: SetupFacts(cores: 2));
      await _toStep(tester, 5);
      expect(find.textContaining('lower screen share limit'), findsOneWidget);
    });

    testWidgets('a roomy machine gets no recommendations', (tester) async {
      await pumpAdminSetup(tester);
      expect(find.text('Suggested for this server'), findsNothing);
    });
  });

  group('layout', () {
    testWidgets('a wide window shows a centred card', (tester) async {
      await pumpAdminSetup(tester);
      final card = tester.getRect(
        find
            .ancestor(
              of: find.text('Your server'),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(card.width, kAdminSetupCardWidth);
      expect(card.center.dx, 640);
    });

    testWidgets('a phone shows a full page', (tester) async {
      await pumpAdminSetup(tester, size: const Size(390, 844));
      final page = tester.getRect(
        find
            .ancestor(
              of: find.text('Your server'),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(page.width, 390);
    });
  });
}
