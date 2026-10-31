// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the rail says when it cannot show a channel list, and whether a retry
/// is worth offering for it.
///
/// Split out of `channel_rail.dart` so that file stays inside the review
/// budget, and so the copy can be asserted without pumping the whole rail.
library;

import 'package:flutter/material.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../sync/providers/sync_failure.dart';

/// A failure the rail is willing to show, with the recovery that actually
/// applies to it.
///
/// A refusal is not [retryable]: asking again would send the same request to a
/// server that already said no. Its control is [retryLabel] "Sign in again".
class RailFailure {
  const RailFailure({
    required this.message,
    required this.retryable,
    this.retryLabel = 'Retry',
  });

  final String message;
  final bool retryable;

  /// What the one recovery control says: a refusal is not fixed by asking
  /// again, so its control signs out instead of retrying.
  final String retryLabel;
}

/// The rail's failure when the local store would not open.
///
/// Nothing on this path touched the network, so the copy must not blame it: the
/// flat "Could not load channels." it replaces is what the owner read as the
/// server being down while he was signed in and connected.
///
/// Shorter than `localStoreErrorMessage`, which says the same things in full:
/// that paragraph is written for a full-width pane, and `ConversationPane`
/// renders it in one directly beside this rail at every width that shows both.
RailFailure localStoreRailFailure(Object error) => RailFailure(
  message: switch (error) {
    LocalDatabaseKeyUnavailable() =>
      "This device's secure storage is locked, so the saved channels "
          'cannot be read.',
    DatabaseEncryptionUnavailable() =>
      'This build cannot keep channels on this device.',
    DatabaseInUseElsewhere() =>
      'Another copy of slim-m is using the saved channels. Quit it, '
          'including from the system tray, then retry.',
    DatabaseUnopenable() =>
      'The saved channels could not be opened or replaced. Retry, or '
          'restart your computer.',
    // Named, so a screenshot of this is enough to know what failed.
    _ =>
      'The channel list saved on this device could not be opened '
          '(${error.runtimeType}).',
  },
  retryable: true,
);

/// The rail's failure when it has no channels at all and sync knows why.
///
/// Returns null while sync is fine, or has a cached list to show: an offline
/// blip with channels already on screen is the header dot's job, and a second
/// indicator for it is the duplication `RailConnectionBar` was retired from
/// the wide rail to remove.
RailFailure? emptyRailFailure(SyncFailure? failure) => switch (failure) {
  null => null,
  SyncFailure.unreachable => const RailFailure(
    message: 'No channels yet: this device cannot reach the server.',
    retryable: true,
  ),
  SyncFailure.refused => const RailFailure(
    message: 'The server refused this session, so it sent no channels.',
    retryable: false,
    retryLabel: 'Sign in again',
  ),
};

/// The failure itself, sized to its own content and parked at the top of the
/// rail.
///
/// Top, not centred: the rail is a tall narrow column, and a centred box left
/// one line of text floating in the middle of it with nothing to anchor to.
/// Sized to content because the same box stretched to the rail's full height
/// read as the whole sidebar having failed rather than one fetch.
class RailFailureNotice extends StatelessWidget {
  const RailFailureNotice({
    super.key,
    required this.failure,
    required this.onRetry,
    required this.onSignInAgain,
  });

  final RailFailure failure;
  final VoidCallback onRetry;
  final VoidCallback onSignInAgain;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s12),
        child: AppErrorState(
          key: const Key('rail-failure'),
          message: failure.message,
          retryLabel: failure.retryLabel,
          onRetry: failure.retryable ? onRetry : onSignInAgain,
        ),
      ),
    );
  }
}
