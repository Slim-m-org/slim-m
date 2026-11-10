// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Brings a share from the OS into the account that will receive it.
///
/// A share only ever lands in a signed-in account, so with several the
/// picker asks which one first (see `ShareToScreen`); with none, the share
/// waits in the active container and the router's redirect resumes it once
/// sign-in finishes. Cold start and warm start take the same path: the
/// launching share is read once at startup and later ones announce
/// themselves through [ShareSource.arrivals].
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../accounts/providers/account_providers.dart';
import 'incoming_share.dart';
import 'share_source.dart';

/// Read once from bootstrap, next to the deep-link controller.
final shareIntakeControllerProvider = Provider<void>((ref) {
  final source = ref.read(shareSourceProvider);
  Future<void> pull() async {
    final share = await source.take();
    if (share != null) deliverShare(ref, share);
  }

  final sub = source.arrivals.listen((_) => unawaited(pull()));
  ref.onDispose(sub.cancel);
  unawaited(pull());
});

/// Puts [share] where the person can act on it and brings that account forward.
///
/// Which server it goes to is asked by the picker itself when several are
/// signed in, because accounts that start in the background are not known to
/// be signed in yet on a cold start.
void deliverShare(Ref ref, IncomingShare share) {
  final host = ref.read(accountHostProvider);
  if (host == null) {
    ref.container.read(pendingShareProvider.notifier).state = PendingShare(
      share,
    );
    return;
  }
  final target = host.active?.signedIn ?? false
      ? host.active
      : host.accounts.where((runtime) => runtime.signedIn).firstOrNull ??
            host.active;
  if (target == null) return;
  target.container.read(pendingShareProvider.notifier).state = PendingShare(
    share,
  );
  if (target != host.active && target.account != null) {
    unawaited(host.switchTo(target.account!.origin));
  }
}

/// Gives the pending share to the server at [origin], bringing it forward.
///
/// Returns false when [origin] is the one already on screen, which keeps the
/// share where it is and only stops asking which server.
bool chooseShareServer(WidgetRef ref, String origin) {
  final pending = ref.read(pendingShareProvider);
  final host = ref.read(accountHostProvider);
  final target = host?.runtimeFor(origin);
  if (pending == null || host == null || target == null) return false;
  final here = target == host.active;
  if (!here) ref.read(pendingShareProvider.notifier).state = null;
  target.container.read(pendingShareProvider.notifier).state = PendingShare(
    pending.share,
    serverChosen: true,
  );
  if (!here) unawaited(host.switchTo(origin));
  return !here;
}
