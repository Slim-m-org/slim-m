// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One string that carries both halves of an invite: which server, and which
/// code.
///
/// Handing somebody an invite used to mean telling them two things - the
/// server address and the code - and having them type both into onboarding.
/// A link carries both, so they paste once.
///
/// Deliberately a `slimm://` scheme rather than an `https://` URL. Nothing
/// serves the web client today (see `docs/OPEN-QUESTIONS.md`), so an https
/// invite link would look clickable and open a 404, which is worse than
/// handing over a bare code. A custom scheme cannot masquerade as a page
/// that works, and registering it later so a click opens the app needs only
/// an Info.plist entry and an intent filter - no domain verification, unlike
/// universal links.
///
/// Parsing does no validation of the server beyond its shape, on purpose. A
/// server address somebody sent you is exactly as untrusted as one you typed,
/// so a parsed link only fills the fields in and the ordinary checks
/// (`requireSecureScheme`, `reduceServerAddress`, and the live probe) still
/// run on it. Skipping them here would turn a pasted string into a way past
/// the guards typing one has to clear.
library;

import 'link_query.dart';

/// The scheme and host an invite link uses. `slimm://join?...`.
const _scheme = 'slimm';
const _host = 'join';

/// Builds the link for [code] on [server].
///
/// [server] is written out whole rather than reduced to a host, because the
/// scheme and any port are both load-bearing for reaching a self-hosted
/// deployment, and dropping them would make the link work only for the
/// default case.
String buildInviteLink({required Uri server, required String code}) => Uri(
  scheme: _scheme,
  host: _host,
  queryParameters: {'server': server.toString(), 'code': code},
).toString();

/// What a pasted invite link says, or null if [text] is not one.
///
/// Null covers every kind of not-a-link - a bare code, a web address, an
/// empty paste - because the caller's response to all of them is the same:
/// leave the fields alone and let the person type. There is nothing here for
/// an error message to usefully distinguish.
({Uri server, String code})? parseInviteLink(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || uri.scheme != _scheme || uri.host != _host) return null;

  final query = queryOrNull(uri);
  if (query == null) return null;
  final rawServer = query['server']?.trim() ?? '';
  final code = query['code']?.trim() ?? '';
  if (rawServer.isEmpty || code.isEmpty) return null;

  final server = Uri.tryParse(rawServer);
  if (server == null || !server.hasScheme || server.host.isEmpty) return null;

  return (server: server, code: code);
}

/// Whether [code] has the shape of a pasted URL or path rather than a code.
///
/// Invite codes are bare letters and digits, so anything with a separator in it
/// would otherwise be spliced into the check request's path.
bool looksLikeWebAddress(String code) =>
    RegExp(r'[/:?#\s]').hasMatch(code.trim());
