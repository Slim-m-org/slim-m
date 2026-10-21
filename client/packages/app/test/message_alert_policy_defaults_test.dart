// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Posts that read as mentions on an everything default: channels this account
/// cannot post in, and posts by bots and webhooks. A channel override still wins.
library;

import 'package:flutter_test/flutter_test.dart';

import 'support/message_alert_policy_rig.dart';

void main() {
  late AlertRig rig;

  Future<void> wire(AlertRig next) async {
    rig = next;
    await rig.start();
    addTearDown(rig.dispose);
  }

  group('a channel this account cannot post in', () {
    test('an everything default reads as mentions there', () async {
      await wire(AlertRig()..readOnly = {'group-1'});

      expect(
        await alertsFor(rig, alertMessage('group-1', 'new article')),
        isFalse,
      );
      expect(await alertsFor(rig, alertMessage('group-1', 'hi @nick')), isTrue);
    });

    test('an override for the channel still gets every post', () async {
      await wire(
        AlertRig(overrides: {'group-1': 'everything'})..readOnly = {'group-1'},
      );

      expect(
        await alertsFor(rig, alertMessage('group-1', 'new article')),
        isTrue,
      );
    });

    test('posting rights are only asked when they could matter', () async {
      await wire(AlertRig(account: 'mentions')..readOnly = {'group-1'});

      await alertsFor(rig, alertMessage('group-1', 'hi all'));
      await alertsFor(rig, alertMessage('dm-1', 'hello'));

      expect(rig.permissionRequests, 0);
    });
  });

  group('a post by a bot or webhook', () {
    test('an everything default reads as mentions', () async {
      await wire(AlertRig()..automated = {'feedbot': 'bot'});

      final plain = alertMessage('group-1', 'new article', authorId: 'feedbot');
      final mention = alertMessage('group-1', 'hi @nick', authorId: 'feedbot');
      expect(await alertsFor(rig, plain), isFalse);
      expect(await alertsFor(rig, mention), isTrue);
    });

    test('a webhook is treated the same way', () async {
      await wire(AlertRig()..automated = {'hook': 'webhook'});

      expect(
        await alertsFor(
          rig,
          alertMessage('group-1', 'built', authorId: 'hook'),
        ),
        isFalse,
      );
    });

    test('a failed author lookup reads as a person and still alerts', () async {
      await wire(
        AlertRig()
          ..automated = {'feedbot': 'bot'}
          ..usersFail = true,
      );
      final plain = alertMessage('group-1', 'new article', authorId: 'feedbot');
      expect(await alertsFor(rig, plain), isTrue);
    });

    test('a lookup that never answers falls open after its timeout', () async {
      await wire(AlertRig()..usersHang = true);
      final plain = alertMessage('group-1', 'new article', authorId: 'feedbot');
      expect(await alertsFor(rig, plain), isTrue);
    });

    test(
      'a webhook name alone marks a post automated, with no lookup',
      () async {
        await wire(AlertRig()..usersFail = true);
        final plain = alertMessage(
          'group-1',
          'built',
          authorId: 'feedbot',
          webhookUsername: 'CI',
        );
        expect(await alertsFor(rig, plain), isFalse);
      },
    );

    test('a person still alerts on the default', () async {
      await wire(AlertRig());

      expect(await alertsFor(rig, alertMessage('group-1', 'hi')), isTrue);
    });

    test('an override for the channel still gets every post', () async {
      await wire(
        AlertRig(overrides: {'group-1': 'everything'})
          ..automated = {'feedbot': 'bot'},
      );

      final plain = alertMessage('group-1', 'new article', authorId: 'feedbot');
      expect(await alertsFor(rig, plain), isTrue);
    });

    test('a bot direct message still alerts', () async {
      await wire(AlertRig()..automated = {'feedbot': 'bot'});

      expect(
        await alertsFor(
          rig,
          alertMessage('dm-1', 'hello', authorId: 'feedbot'),
        ),
        isTrue,
      );
    });
  });
}
