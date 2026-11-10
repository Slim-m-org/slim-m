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

import '../../accounts/providers/account_host.dart';
import '../../accounts/providers/account_providers.dart';
import 'incoming_share.dart';
import 'share_source.dart';

/// Listens for shares for the whole life of the app.
///
/// Not a provider: a provider dies with its container, and the container
/// bootstrap reads it from is retired when the launch-time account is removed.
class ShareIntake {
  ShareIntake._(this._source, this._host, this._home);

  /// Reads the source and host once from [container], then outlives it.
  factory ShareIntake.start(ProviderContainer container) {
    final intake = ShareIntake._(
      container.read(shareSourceProvider),
      container.read(accountHostProvider),
      container,
    );
    intake._sub = intake._source.arrivals.listen(
      (_) => unawaited(intake._pull()),
    );
    unawaited(intake._pull());
    return intake;
  }

  final ShareSource _source;
  final AccountHost? _host;

  /// Holds the share only when there is no host to pick an account.
  final ProviderContainer _home;
  late final StreamSubscription<void> _sub;

  Future<void> _pull() async {
    final share = await _source.take();
    if (share != null) deliverShare(_host, _home, share);
  }

  void dispose() => unawaited(_sub.cancel());
}

/// Puts [share] where the person can act on it and brings that account forward.
///
/// Which server it goes to is asked by the picker itself when several are
/// signed in, because accounts that start in the background are not known to
/// be signed in yet on a cold start.
void deliverShare(
  AccountHost? host,
  ProviderContainer home,
  IncomingShare share,
) {
  if (host == null) {
    home.read(pendingShareProvider.notifier).state = PendingShare(share);
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
