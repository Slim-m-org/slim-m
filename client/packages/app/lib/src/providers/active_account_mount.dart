// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps app-wide providers mounted for the whole life of the app.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/accounts/providers/account_host.dart';

/// Keeps [providers] listened to on whichever account is on screen.
///
/// Not a provider: a provider dies with its container, and the container
/// bootstrap starts from is retired when the launch-time account is removed.
class ActiveAccountMount {
  ActiveAccountMount._(this._host, this._home, this._providers);

  /// Mounts [providers] on [home] when there is no host to follow.
  factory ActiveAccountMount.start(
    AccountHost? host,
    ProviderContainer home,
    List<ProviderListenable<Object?>> providers,
  ) {
    final mount = ActiveAccountMount._(host, home, providers);
    host?.addListener(mount._follow);
    mount._follow();
    return mount;
  }

  final AccountHost? _host;
  final ProviderContainer _home;
  final List<ProviderListenable<Object?>> _providers;
  ProviderContainer? _source;
  var _subs = <ProviderSubscription<Object?>>[];

  void _follow() {
    final container = _host == null ? _home : _host.active?.container;
    if (container == _source) return;
    _closeSubs();
    _source = container;
    if (container == null) return;
    _subs = [
      for (final provider in _providers) container.listen(provider, (_, _) {}),
    ];
  }

  void _closeSubs() {
    for (final sub in _subs) {
      sub.close();
    }
    _subs = [];
  }

  void dispose() {
    _host?.removeListener(_follow);
    _closeSubs();
    _source = null;
  }
}
