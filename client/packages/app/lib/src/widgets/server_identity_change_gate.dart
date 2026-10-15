// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Stops a signed-in session whose server now presents a different key than
/// the one pinned, until the person decides (decision 0036).
///
/// Trusting re-pins and carries on; cancelling ends the session, since staying
/// signed in would keep sending the token to a server nobody vouched for.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../providers/server_identity_recheck.dart';
import '../providers/sync_controller.dart';
import 'server_identity_changed_step.dart';
import 'server_identity_confirmation.dart';

/// Renders [child] unless the server's key no longer matches its pin.
class ServerIdentityChangeGate extends ConsumerWidget {
  const ServerIdentityChangeGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final changed = ref.watch(serverIdentityChangeProvider).valueOrNull;
    if (changed == null) return child;
    final server = ref.watch(serverUrlProvider);
    final presented = changed.presented;
    return ServerIdentityChangedStep(
      address: server,
      identity: presented,
      onDecision: (trusted) async {
        if (trusted && presented != null) {
          await ref
              .read(keyStoreProvider)
              .put(identityHandleFor(server), presented.publicKey);
          ref.invalidate(serverIdentityChangeProvider);
          return;
        }
        await ref.read(syncControllerProvider.notifier).stop();
        ref
            .read(sessionProvider)
            .clear(reason: "This server's identity changed");
      },
    );
  }
}
