// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether an SFU address is safe to join, split out of `voice_controller.dart`
/// to make room there for the camera-control additions the file's own review
/// budget would not otherwise fit.
library;

import '../../../server_scheme_policy.dart' show isLocalAddress;

/// Refuses a plaintext SFU address unless it is on a LAN.
///
/// `token.url` is `SLIMM_LIVEKIT_URL` off the wire, verbatim and
/// unauthenticated as a value: the server already permits `ws://` for a
/// self-hosted LAN SFU, exactly the case [isLocalAddress] carves out for the
/// server address itself, so joining a call is not the place to add a
/// stricter rule than connecting already applies. What it must not do is let
/// an operator's plaintext LAN setting quietly reach a *public* deployment,
/// which would send a user's microphone and screen share unencrypted with
/// nothing on screen to say so. This stays in the app package rather than
/// the `rtc` package: [isLocalAddress] is one of the app's own connection
/// rules - the same one `server_scheme_policy.dart` applies to a server
/// address - and `rtc` has no dependency on the app to reuse it from.
String? insecureSfuReason(String rawUrl) {
  final uri = Uri.tryParse(rawUrl);
  if (uri != null) {
    if (_secureSfuSchemes.contains(uri.scheme)) return null;
    if (_plaintextSfuSchemes.contains(uri.scheme) && isLocalAddress(uri)) {
      return null;
    }
  }
  return "This Space's voice server (SLIMM_LIVEKIT_URL) is not using an "
      'encrypted address, so joining would send microphone and screen-share '
      'media across the network in the clear. Ask whoever runs this Space to '
      'fix that setting.';
}

/// The four schemes `SLIMM_LIVEKIT_URL` accepts, split by whether they encrypt.
///
/// All four are the server's, not a guess: `voice/mod.rs`'s `http_url_for`
/// takes `wss`, `ws`, `https` and `http`, and LiveKit serves signalling on both
/// pairs, so checking only for `wss` would refuse a perfectly secure
/// `https://` deployment. An unparseable url falls through to the refusal,
/// which fails closed.
const _secureSfuSchemes = {'wss', 'https'};
const _plaintextSfuSchemes = {'ws', 'http'};
