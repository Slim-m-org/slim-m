// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A pinned server must sign a fresh challenge with its key before the session
/// reaches it, so a host that copied the public key is held like a changed one.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/auth/providers/server_identity_proof.dart';
import 'package:slimm_app/src/features/auth/providers/server_identity_recheck.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';

import '../../support/identity_rig.dart';

void main() {
  setUp(() => HttpOverrides.global = null);

  test('a server that signs the challenge is let through, and the proof is '
      'remembered', () async {
    final rig = await identityRig(realKey: true);
    rig.container.read(syncControllerProvider.notifier);

    await rig.untilLive();

    expect(rig.server.proofsAsked, greaterThan(0));
    expect(rig.server.bearers, {'Bearer access-1'});
    expect(
      await rig.keys.read(identityProofHandleFor(rig.server.url)),
      rig.server.presentedKey,
    );
  });

  test(
    'a host replaying the pinned key without the private key is held',
    () async {
      final rig = await identityRig(realKey: true);
      rig.server.proof = ProofAnswer.forges;
      rig.container.read(syncControllerProvider.notifier);

      final mismatch = await rig.container.read(
        serverIdentityChangeProvider.future,
      );
      await rig.quiet();

      expect(mismatch, isNotNull);
      expect(mismatch!.presented, isNull);
      expect(rig.server.signedIn, isEmpty);
      expect(rig.server.socketsOpened, 0);
    },
  );

  test(
    'an address that proved its key once and now skips the proof is held',
    () async {
      final rig = await identityRig(realKey: true);
      await rig.keys.put(
        identityProofHandleFor(rig.server.url),
        rig.server.presentedKey!,
      );
      rig.server.proof = ProofAnswer.absent;
      rig.container.read(syncControllerProvider.notifier);

      final mismatch = await rig.container.read(
        serverIdentityChangeProvider.future,
      );
      await rig.quiet();

      expect(mismatch, isNotNull);
      expect(rig.server.signedIn, isEmpty);
    },
  );

  test(
    'a server older than the challenge that never proved is let through',
    () async {
      final rig = await identityRig();
      rig.container.read(syncControllerProvider.notifier);

      await rig.untilLive();

      expect(rig.server.proofsAsked, greaterThan(0));
      expect(rig.server.bearers, {'Bearer access-1'});
    },
  );
}
