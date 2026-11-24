// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What linking a Spotify account needs from the owner (decision 0044).
///
/// The client id is not a secret (the PKCE flow has no client secret), but
/// it belongs to an app only the owner can register, so it is a build-time
/// define and the whole feature is absent from a build that does not set it:
/// `--dart-define=SLIMM_SPOTIFY_CLIENT_ID=<id>`.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _clientId = String.fromEnvironment('SLIMM_SPOTIFY_CLIENT_ID');

/// Registered in the Spotify dashboard exactly as written, for every platform.
const spotifyRedirectUri = 'slimm://spotify-callback';

/// The one permission asked for: what is playing, nothing else.
const spotifyScope = 'user-read-currently-playing';

/// Empty when this build has no Spotify app behind it, and on the web, where the `slimm://` redirect can never come back to a tab. Overridden in tests.
final spotifyClientIdProvider = Provider<String>(
  (ref) => kIsWeb ? '' : _clientId,
);
