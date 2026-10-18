// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One string that carries both halves of an invite: which server, and which
/// code.
///
/// The shared form is `https://<server>/invite/<code>`, which chat apps
/// linkify and the server answers with a landing page that opens the app
/// (`slimm://join`) or the web client. The `slimm://` form stays accepted
/// everywhere a link is pasted or tapped.
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

/// Builds the shareable https link for [code] on [server].
///
/// Scheme and port are kept, because they are load-bearing for reaching a
/// self-hosted deployment.
String buildInviteLink({required Uri server, required String code}) => Uri(
  scheme: server.scheme,
  host: server.host,
  port: server.hasPort ? server.port : null,
  pathSegments: [
    ...server.pathSegments.where((s) => s.isNotEmpty),
    'invite',
    code,
  ],
).toString();

/// The `slimm://join` form of the link, which opens the installed app.
String buildDeepInviteLink({required Uri server, required String code}) => Uri(
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
  if (uri == null) return null;
  if (uri.scheme == 'https' || uri.scheme == 'http') {
    return _parseWebInvite(uri);
  }
  if (uri.scheme != _scheme || uri.host != _host) return null;
  return parseInviteQuery(uri);
}

/// The invite in `?server=&code=` [uri], the shared shape of the `slimm://`
/// link and the web client's `/join` route.
({Uri server, String code})? parseInviteQuery(Uri uri) {
  final query = queryOrNull(uri);
  if (query == null) return null;
  final rawServer = query['server']?.trim() ?? '';
  final code = query['code']?.trim() ?? '';
  if (rawServer.isEmpty || code.isEmpty) return null;

  final server = Uri.tryParse(rawServer);
  if (server == null || !server.hasScheme || server.host.isEmpty) return null;

  return (server: server, code: code);
}

({Uri server, String code})? _parseWebInvite(Uri uri) {
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (uri.host.isEmpty ||
      segments.length < 2 ||
      segments[segments.length - 2] != 'invite') {
    return null;
  }
  final code = segments.last.trim();
  final server = Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    pathSegments: segments.sublist(0, segments.length - 2),
  );
  return (server: server, code: code);
}

/// Whether [code] has the shape of a pasted URL or path rather than a code.
///
/// Invite codes are bare letters and digits, so anything with a separator in it
/// would otherwise be spliced into the check request's path.
bool looksLikeWebAddress(String code) =>
    RegExp(r'[/:?#\s]').hasMatch(code.trim());
