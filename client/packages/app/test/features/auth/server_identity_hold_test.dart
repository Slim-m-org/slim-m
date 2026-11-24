// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A server whose key contradicts its pin gets no signed-in request and no
/// socket until the person chooses (decision 0036).
///
/// The real api client and sync controller run against a loopback server, so
/// what it records is what would have reached a real one.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/auth/providers/server_identity_recheck.dart';
import 'package:slimm_app/src/features/auth/providers/server_version_probe.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';

import '../../support/identity_rig.dart';
import '../../support/window_lifecycle.dart';

void main() {
  // The widget binding the last test brings in answers every request with a 400 of its own.
  setUp(() => HttpOverrides.global = null);

  test(
    'a changed key gets no signed-in request and no socket until trusted',
    () async {
      final rig = await identityRig();
      rig.server.presentedKey = identityKeyB;
      rig.container.read(syncControllerProvider.notifier);

      final mismatch = await rig.container.read(
        serverIdentityChangeProvider.future,
      );
      expect(mismatch, isNotNull);
      await rig.quiet();

      expect(rig.server.signedIn, isEmpty);
      expect(rig.server.socketsOpened, 0);
      expect(rig.status, isNot(SyncStatus.live));

      await rig.trustPresentedKey();
      await rig.untilLive();

      expect(rig.server.signedIn, contains('POST /auth/ws-ticket'));
      expect(rig.server.bearers, {'Bearer access-1'});
      expect(rig.server.socketsOpened, 1);
    },
  );

  test('a pinned server that reports no key is held until accepted', () async {
    final rig = await identityRig();
    rig.server.presentedKey = null;
    rig.container.read(syncControllerProvider.notifier);

    await rig.container.read(serverIdentityChangeProvider.future);
    await rig.quiet();
    expect(rig.server.signedIn, isEmpty);
    expect(rig.server.socketsOpened, 0);

    rig.container
        .read(serverIdentityChangeProvider.notifier)
        .acceptMissingIdentity();
    await rig.untilLive();
    expect(rig.server.bearers, {'Bearer access-1'});
  });

  for (final answer in [
    VersionAnswer.serverError,
    VersionAnswer.notFoundPage,
  ]) {
    test('a pinned server answering /version with ${answer.name} is held '
        'until accepted', () async {
      final rig = await identityRig();
      rig.server.probe = answer;
      rig.container.read(syncControllerProvider.notifier);

      final mismatch = await rig.container.read(
        serverIdentityChangeProvider.future,
      );
      await rig.quiet();
      expect(mismatch?.presented, isNull);
      expect(rig.server.signedIn, isEmpty);
      expect(rig.server.socketsOpened, 0);

      rig.server.probe = VersionAnswer.answers;
      rig.container
          .read(serverIdentityChangeProvider.notifier)
          .acceptMissingIdentity();
      await rig.untilLive();
      expect(rig.server.bearers, {'Bearer access-1'});
    });
  }

  test('a /version that hangs up lets the session through', () async {
    final rig = await identityRig();
    rig.server.probe = VersionAnswer.hangsUp;
    rig.container.read(syncControllerProvider.notifier);

    await rig.untilLive();

    expect(rig.server.versionReads, greaterThan(0));
    expect(rig.server.bearers, {'Bearer access-1'});
  });

  test(
    'a matching pin waits for one /version answer and adds no second',
    () async {
      final rig = await identityRig();
      rig.server.versionDelay = const Duration(milliseconds: 300);
      rig.container.read(syncControllerProvider.notifier);

      await rig.untilLive();

      expect(rig.server.versionReadsAtFirstSignedIn, 1);
      expect(rig.server.versionsAnsweredAtFirstSignedIn, 1);
    },
  );

  test('nothing pinned yet is not held for a /version read', () async {
    final rig = await identityRig(pinned: null);
    rig.server.probe = VersionAnswer.serverError;
    rig.container.read(syncControllerProvider.notifier);

    await rig.untilLive();

    expect(rig.server.versionReadsAtFirstSignedIn, 0);
  });

  test('a key that changes mid-session stops sync instead of looping, and '
      'trusting it restarts', () async {
    final rig = await identityRig();
    rig.container.read(syncControllerProvider.notifier);
    await rig.untilLive();
    final before = rig.server.signedIn.length;
    expect(rig.server.socketsOpened, 1);

    rig.server.presentedKey = identityKeyB;
    rig.container.invalidate(serverVersionReadProvider);
    await rig.until(
      () =>
          rig.container.read(serverIdentityChangeProvider).valueOrNull != null,
      'proved the mismatch',
    );
    await rig.until(() => rig.status == SyncStatus.offline, 'stood down');
    await rig.quiet();

    expect(rig.server.socketsOpened, 1);
    expect(rig.server.signedIn.length, before);
    expect(rig.server.sockets, isEmpty);

    await rig.trustPresentedKey();
    await rig.untilLive();

    expect(rig.server.socketsOpened, 2);
    expect(rig.server.signedIn.length, greaterThan(before));
  });

  test('a call made while a key is in question waits for the choice', () async {
    final rig = await identityRig();
    rig.server.presentedKey = identityKeyB;
    final api = rig.container.read(apiProvider);

    var answered = false;
    final channels = api.listChannels().then((_) => answered = true);
    await rig.container.read(serverIdentityChangeProvider.future);
    await rig.quiet();
    expect(answered, isFalse);
    expect(rig.server.signedIn, isEmpty);

    await rig.trustPresentedKey();
    await channels;
    expect(rig.server.signedIn, contains('GET /channels'));
  });

  testWidgets('a key that changes behind a plain-http reconnect holds it and '
      'stops sync in a hidden window', (tester) async {
    late IdentityRig rig;
    await tester.runAsync(() async {
      rig = await identityRig();
      rig.container.read(syncControllerProvider.notifier);
      await rig.untilLiveAndRechecked();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: rig.container,
        child: const SizedBox(),
      ),
    );
    await hideTestWindow(tester);

    await tester.runAsync(() async {
      final asked = rig.server.versionReads;
      final signedIn = rig.server.signedIn.length;
      rig.server.presentedKey = identityKeyB;
      for (final socket in List.of(rig.server.sockets)) {
        await socket.close();
      }
      await rig.until(() => rig.server.versionReads > asked, 'asked again');
      await rig.until(() => rig.status == SyncStatus.offline, 'stood down');
      await rig.quiet();

      expect(rig.server.socketsOpened, 1, reason: 'the reconnect was held');
      expect(rig.server.signedIn.length, signedIn);
    });
  });
}
