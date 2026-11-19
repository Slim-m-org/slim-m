// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The widget the whole app hangs from: one provider scope per account.
/// See docs/decisions/0068-multiple-servers-in-one-app.md.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/account_host.dart';

/// Shows the active account's app, and keeps every account's container under
/// a mounted scope whether it is on screen or not.
///
/// A switch swaps what is under the active scope, so nothing of the previous
/// account stays on screen. The scopes themselves stay: a container whose only
/// scope unmounts with a refresh or a disposal queued never runs that queue
/// again (docs/internals.md, account scopes).
class AccountRoot extends StatelessWidget {
  const AccountRoot({super.key, required this.host, required this.app});

  final AccountHost host;

  /// What the active account shows.
  final Widget app;

  /// The active account first: a tree torn down in order then lets go of the
  /// other accounts, a row naming one say, while their scopes still stand.
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: host,
    builder: (context, _) => Stack(
      fit: StackFit.expand,
      textDirection: TextDirection.ltr,
      children: [
        for (final runtime in host.runtimes)
          if (runtime == host.active) _scope(runtime, app),
        for (final runtime in host.runtimes)
          if (runtime != host.active) _scope(runtime, const SizedBox.shrink()),
      ],
    ),
  );

  Widget _scope(AccountRuntime runtime, Widget child) =>
      UncontrolledProviderScope(
        key: ObjectKey(runtime.container),
        container: runtime.container,
        child: child,
      );
}
