// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a Spotify link attempt stands, for Settings to show in place
/// (decision 0056).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

sealed class SpotifyLinkStatus {
  const SpotifyLinkStatus();
}

/// Nothing linked and nothing in progress.
class SpotifyUnlinked extends SpotifyLinkStatus {
  const SpotifyUnlinked();
}

/// The browser is open on Spotify's consent page.
class SpotifyWaiting extends SpotifyLinkStatus {
  const SpotifyWaiting();
}

/// The redirect arrived and the code is being traded for tokens.
class SpotifyConnecting extends SpotifyLinkStatus {
  const SpotifyConnecting();
}

class SpotifyConnected extends SpotifyLinkStatus {
  const SpotifyConnected(this.name);

  /// Spotify's display name for the account, when it said.
  final String? name;

  String get text =>
      name == null ? 'Connected to Spotify' : 'Connected as $name';
}

/// The attempt ended without a link; [message] stays until dismissed.
class SpotifyFailed extends SpotifyLinkStatus {
  const SpotifyFailed(this.message);

  final String message;
}

class SpotifyLinkStatusController extends StateNotifier<SpotifyLinkStatus> {
  SpotifyLinkStatusController(super.initial);

  void set(SpotifyLinkStatus next) {
    if (mounted) state = next;
  }
}
