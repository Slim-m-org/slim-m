// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A notification tap lands on the server it came from, not the one on screen.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/deep_links.dart';
import 'package:slimm_app/src/invite_link.dart';
import 'package:slimm_app/src/message_link.dart';
import 'package:slimm_app/src/features/accounts/providers/notification_target.dart';
import 'package:slimm_app/src/providers/notification_tap_router.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/router.dart';

import 'account_host_harness.dart';

const _a = 'https://first.example';
const _b = 'https://second.example';

String _location(AccountHarness h, String origin) => h.host
    .runtimeFor(origin)!
    .container
    .read(routerProvider)
    .routeInformationProvider
    .value
    .uri
    .toString();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AccountHarness h;
  var made = false;
  tearDown(() async {
    if (made) await h.dispose();
    made = false;
  });

  Future<void> bootTwo() async {
    h = AccountHarness();
    made = true;
    await h.seed(_a, user: 'ann', active: true);
    await h.seed(_b, user: 'bea');
    await h.boot();
    final store = await h.host
        .runtimeFor(_b)!
        .container
        .read(storeProvider.future);
    await store.upsertChannels([
      const api.Channel(id: 'cb', name: 'beta', kind: 'text', createdAt: 0),
    ]);
  }

  test('a payload naming the other server switches to it first', () async {
    await bootTwo();
    expect(h.host.active!.account!.origin, _a);

    await openChannelOnOwner(h.host, 'cb', origin: _b);
    await pumpEventQueueTimes();

    expect(h.host.active!.account!.origin, _b);
    expect(_location(h, _b), contains('/channels/cb'));
  });

  test('a push naming only the channel finds the server that has it', () async {
    await bootTwo();

    await openChannelOnOwner(h.host, 'cb');
    await pumpEventQueueTimes();

    expect(h.host.active!.account!.origin, _b);
    expect(_location(h, _b), contains('/channels/cb'));
  });

  test('a channel no server knows opens on the one on screen', () async {
    await bootTwo();

    await openChannelOnOwner(h.host, 'nowhere');
    await pumpEventQueueTimes();

    expect(h.host.active!.account!.origin, _a);
    expect(_location(h, _a), contains('/channels/nowhere'));
  });

  group('a tapped link', () {
    late StreamController<Uri> links;

    Future<void> bootLinked() async {
      links = StreamController<Uri>.broadcast();
      h = AccountHarness(
        extraOverrides: [deepLinkUrisProvider.overrideWithValue(links.stream)],
      );
      made = true;
      await h.seed(_a, user: 'ann', active: true);
      await h.seed(_b, user: 'bea');
      await h.boot();
      h.host.accounts.first.container.read(deepLinkControllerProvider);
    }

    tearDown(() async {
      if (made) await links.close();
    });

    test('to a message on the other server switches to it', () async {
      await bootLinked();

      links.add(
        Uri.parse(
          buildMessageLink(
            server: Uri.parse(_b),
            channelId: 'cb',
            messageId: 'm1',
          ),
        ),
      );
      await pumpEventQueueTimes();

      expect(h.host.active!.account!.origin, _b);
    });

    test('an invite to a new server opens the add flow for it', () async {
      await bootLinked();

      links.add(
        Uri.parse(
          buildDeepInviteLink(
            server: Uri.parse('https://third.example'),
            code: 'abc',
          ),
        ),
      );
      await pumpEventQueueTimes();

      expect(h.host.adding, isTrue);
      expect(h.host.active!.container.read(tappedInviteProvider)?.code, 'abc');
    });
  });

  test('the payload round trips and rejects what it did not write', () {
    const target = NotificationTarget(origin: _b, channelId: 'cb');
    final back = NotificationTarget.decode(target.encode())!;
    expect((back.origin, back.channelId), (_b, 'cb'));
    expect(NotificationTarget.decode(null), isNull);
    expect(NotificationTarget.decode('opaque-envelope'), isNull);
    expect(NotificationTarget.decode('{"o":"x"}'), isNull);
  });
}
