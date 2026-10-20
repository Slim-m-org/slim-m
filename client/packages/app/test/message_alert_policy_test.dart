// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one gate the chime and the desktop banner share: a message alerts only
/// if the preference that applies to it allows it. That preference is the
/// channel's own override, else a thread's parent channel's, else the
/// account's, the order the server resolves it in for push.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/messages/providers/message_alert_policy.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'support/message_alert_policy_rig.dart';

void main() {
  late AlertRig rig;

  Future<void> wire(AlertRig next) async {
    rig = next;
    await rig.start();
    addTearDown(rig.dispose);
  }

  group('the account preference', () {
    test('nothing silences a plain group message', () async {
      await wire(AlertRig(account: 'nothing'));

      expect(await alertsFor(rig, alertMessage('group-1', 'hi all')), isFalse);
    });

    test(
      'mentions silences a plain message and lets a mention through',
      () async {
        await wire(AlertRig(account: 'mentions'));

        expect(
          await alertsFor(rig, alertMessage('group-1', 'hi all')),
          isFalse,
        );
        expect(
          await alertsFor(rig, alertMessage('group-1', 'hi @nick')),
          isTrue,
        );
      },
    );

    test('everything lets a plain message through', () async {
      await wire(AlertRig());

      expect(await alertsFor(rig, alertMessage('group-1', 'hi all')), isTrue);
    });

    test('mentions still lets a direct message through', () async {
      await wire(AlertRig(account: 'mentions'));

      final alert = await rig.policy.evaluate(alertMessage('dm-1', 'hello'));

      expect(alert?.isDm, isTrue);
    });

    test('an unreadable preference silences nothing', () async {
      await wire(AlertRig(account: 'nothing', accountFails: true));

      expect(await alertsFor(rig, alertMessage('group-1', 'hi all')), isTrue);
    });
  });

  group('a channel override', () {
    test('beats an account that would allow it', () async {
      await wire(AlertRig(overrides: {'group-1': 'nothing'}));

      expect(await alertsFor(rig, alertMessage('group-1', 'hi all')), isFalse);
    });

    test('beats an account that would silence it', () async {
      await wire(
        AlertRig(account: 'nothing', overrides: {'group-1': 'mentions'}),
      );

      expect(await alertsFor(rig, alertMessage('group-1', 'hi @nick')), isTrue);
    });
  });

  group('a thread', () {
    test('follows a muted parent channel', () async {
      await wire(AlertRig(overrides: {'group-1': 'nothing'}));

      expect(
        await alertsFor(rig, alertMessage('thread-1', 'a reply')),
        isFalse,
      );
    });

    test('keeps its own override over its parent\'s', () async {
      await wire(
        AlertRig(overrides: {'group-1': 'nothing', 'thread-1': 'mentions'}),
      );

      expect(
        await alertsFor(rig, alertMessage('thread-1', 'hey @nick')),
        isTrue,
      );
      expect(
        await alertsFor(rig, alertMessage('thread-1', 'a reply')),
        isFalse,
      );
    });

    test('follows the account when it has no parent override', () async {
      await wire(AlertRig(account: 'nothing'));

      expect(
        await alertsFor(rig, alertMessage('thread-1', 'a reply')),
        isFalse,
      );
    });

    test('follows the account when the parent cannot be looked up', () async {
      await wire(
        AlertRig(overrides: {'group-1': 'nothing'}, parentFails: true),
      );

      expect(await alertsFor(rig, alertMessage('thread-1', 'a reply')), isTrue);
    });

    test('asks for its parent once', () async {
      await wire(AlertRig());

      await rig.policy.evaluate(alertMessage('thread-1', 'one'));
      await rig.policy.evaluate(alertMessage('thread-1', 'two'));

      expect(rig.threadParentRequests, hasLength(1));
    });
  });

  group('who the message is from', () {
    test('someone blocked never alerts', () async {
      await wire(AlertRig());
      await rig.container.read(blocksProvider.notifier).block('pest');

      expect(
        await alertsFor(rig, alertMessage('group-1', 'hi', authorId: 'pest')),
        isFalse,
      );
    });

    test('a deleted account never alerts', () async {
      await wire(AlertRig());

      expect(
        await alertsFor(rig, alertMessage('group-1', 'hi', authorId: null)),
        isFalse,
      );
    });

    test('yourself never alerts', () async {
      await wire(AlertRig());

      expect(
        await alertsFor(rig, alertMessage('group-1', 'hi', authorId: 'me')),
        isFalse,
      );
    });
  });

  group('what was set on another device', () {
    late Duration originalMaxAge;

    setUp(() {
      originalMaxAge = alertStateMaxAge;
      alertStateMaxAge = const Duration(milliseconds: 40);
    });
    tearDown(() => alertStateMaxAge = originalMaxAge);

    Future<void> pastMaxAge() =>
        Future<void>.delayed(const Duration(milliseconds: 80));

    test('a snooze is honoured once the schedule is stale', () async {
      await wire(AlertRig());
      expect(await alertsFor(rig, alertMessage('group-1', 'hi all')), isTrue);

      rig.snoozeUntil = DateTime.now().millisecondsSinceEpoch + 3600 * 1000;
      await pastMaxAge();

      expect(await alertsFor(rig, alertMessage('group-1', 'hi all')), isFalse);
    });

    test('a fresh schedule is not asked for again', () async {
      await wire(AlertRig());
      await rig.policy.evaluate(alertMessage('group-1', 'one'));
      await rig.policy.evaluate(alertMessage('group-1', 'two'));

      expect(rig.scheduleRequests, 1);
    });

    test('a schedule that failed to load is asked for again', () async {
      final failing = AlertRig()..scheduleFails = true;
      await wire(failing);
      await rig.policy.evaluate(alertMessage('group-1', 'one'));

      rig
        ..scheduleFails = false
        ..snoozeUntil = DateTime.now().millisecondsSinceEpoch + 3600 * 1000;

      expect(await alertsFor(rig, alertMessage('group-1', 'two')), isFalse);
    });

    test('a changed account preference is honoured once it is stale', () async {
      await wire(AlertRig());
      expect(await alertsFor(rig, alertMessage('group-1', 'hi all')), isTrue);

      rig.account = 'nothing';
      await pastMaxAge();

      expect(await alertsFor(rig, alertMessage('group-1', 'hi all')), isFalse);
    });
  });

  group('a mention that is not the username', () {
    test('@everyone gets through a channel narrowed to mentions', () async {
      await wire(AlertRig(overrides: {'group-1': 'mentions'}));

      expect(
        await alertsFor(rig, alertMessage('group-1', '@everyone standup')),
        isTrue,
      );
      expect(
        await alertsFor(rig, alertMessage('group-1', 'quick q @here')),
        isTrue,
      );
    });

    test('a role the account holds does too', () async {
      final holder = AlertRig(overrides: {'group-1': 'mentions'})
        ..roles = ['Core Team'];
      await wire(holder);

      expect(
        await alertsFor(rig, alertMessage('group-1', 'ping @[Core Team]')),
        isTrue,
      );
    });

    test('a role it does not hold stays quiet', () async {
      await wire(AlertRig(overrides: {'group-1': 'mentions'}));

      expect(
        await alertsFor(rig, alertMessage('group-1', 'ping @[Core Team]')),
        isFalse,
      );
    });

    test('an unreadable profile costs only the role mentions', () async {
      await wire(AlertRig(overrides: {'group-1': 'mentions'}));

      expect(await alertsFor(rig, alertMessage('group-1', 'hi @nick')), isTrue);
    });
  });

  group('looking up this account', () {
    test('a burst of messages shares one lookup', () async {
      await wire(AlertRig(overrides: {'group-1': 'mentions'}));

      await Future.wait([
        for (var i = 0; i < 10; i++)
          alertsFor(rig, alertMessage('group-1', 'm $i')),
      ]);

      expect(rig.meRequests, 1);
    });

    test('a refused lookup is not retried for every message', () async {
      await wire(AlertRig(overrides: {'group-1': 'mentions'})..meFails = true);

      for (var i = 0; i < 5; i++) {
        await alertsFor(rig, alertMessage('group-1', 'hi @nick $i'));
      }

      expect(rig.meRequests, 1);
    });

    test('a refused lookup does not hold back another account', () async {
      await wire(AlertRig(overrides: {'group-1': 'mentions'})..meFails = true);
      expect(
        await alertsFor(rig, alertMessage('group-1', 'hi @nick')),
        isFalse,
      );

      rig.meFails = false;
      rig.container
          .read(sessionProvider)
          .set(
            const api.TokenPair(
              userId: 'other',
              accessToken: 'access-2',
              refreshToken: 'refresh-2',
              accessExpiresAt: 0,
            ),
          );

      expect(await alertsFor(rig, alertMessage('group-1', 'hi @nick')), isTrue);
      expect(rig.meRequests, 2);
    });

    test('a refused lookup is tried again once the wait passes', () async {
      final saved = selfLookupRetryAfter;
      selfLookupRetryAfter = Duration.zero;
      addTearDown(() => selfLookupRetryAfter = saved);
      await wire(AlertRig(overrides: {'group-1': 'mentions'})..meFails = true);

      expect(
        await alertsFor(rig, alertMessage('group-1', 'hi @nick')),
        isFalse,
      );
      rig.meFails = false;

      expect(await alertsFor(rig, alertMessage('group-1', 'hi @nick')), isTrue);
      expect(rig.meRequests, 2);
    });
  });
}
