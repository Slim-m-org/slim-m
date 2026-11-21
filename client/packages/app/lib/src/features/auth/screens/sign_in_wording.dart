// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the one sign-in form calls itself at each point, and the notice that
/// opens its create step (decision 0130).
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/server_notice.dart';

/// [firstContact] is a Space this install has not signed in to before, where
/// the person may as easily be new as returning.
String signInTitle({required bool creating, required bool firstContact}) =>
    creating
    ? 'Create an account'
    : firstContact
    ? 'Sign in or create an account'
    : 'Welcome back';

String signInAction({required bool creating, required bool firstContact}) =>
    creating
    ? 'Create account'
    : firstContact
    ? 'Continue'
    : 'Sign in';

/// Whether the form starts on creating: nobody can have an account on an
/// unclaimed Space, and a server too old to say who exists is told by an invite.
bool opensOnCreating(Version? version, {required bool invited}) =>
    version != null &&
    (version.claimed == false || (invited && !version.usernameCheck));

/// Says the typed name has no account before one is made, which is where a
/// misremembered username gets caught.
class NoAccountNotice extends StatelessWidget {
  const NoAccountNotice({super.key, required this.username, this.space});

  final String username;

  /// The Space's own name, when it has said it.
  final String? space;

  @override
  Widget build(BuildContext context) => ServerNotice(
    icon: AppIcons.info,
    message:
        'There is no account named $username on ${space ?? 'this Space'}. '
        'Create it here, or go back if you already have one.',
  );
}
