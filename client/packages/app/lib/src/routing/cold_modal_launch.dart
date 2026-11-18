// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A settings or admin page loaded straight from the address bar has nothing
/// beneath it, so it sat on a bare backdrop with no app to close back to.
library;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'routes.dart';

/// Top-level pages that are a whole screen rather than a panel over the app.
const _ownScreens = {Routes.onboarding, Routes.signIn, Routes.share};

/// Once, for the page a load on [launch] first shows: when it is a panel with
/// no shell beneath, the channels shell takes its place in history and the
/// panel opens again over it.
void putShellUnderColdModal(GoRouter router, {required String launch}) {
  if (launch == '/') return;
  final delegate = router.routerDelegate;
  void firstPage() {
    final config = delegate.currentConfiguration;
    if (config.isEmpty) return;
    delegate.removeListener(firstPage);
    if (!_isColdPanel(config)) return;
    final page = config.uri.toString();
    void reopen() {
      if (delegate.currentConfiguration.uri.path != Routes.channels) return;
      delegate.removeListener(reopen);
      // After the frame: a push made while the router is still applying the last change is dropped.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => router.push<void>(page),
      );
    }

    delegate.addListener(reopen);
    void home() => router.go(Routes.channels);
    final context = delegate.navigatorKey.currentContext;
    context == null ? home() : Router.neglect(context, home);
  }

  delegate.addListener(firstPage);
}

bool _isColdPanel(RouteMatchList config) =>
    config.matches.every((match) => match is! ShellRouteMatch) &&
    !_ownScreens.contains(config.uri.path);
