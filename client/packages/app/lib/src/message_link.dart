// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A link to one message: `slimm://message?server=...&channel=...&id=...`.
///
/// Same scheme and the same shape as `invite_link.dart`, and the same reason
/// for writing the server out whole: the scheme and any port are both
/// load-bearing for reaching a self-hosted deployment, so reducing it to a host
/// would make the link work only for the default case.
///
/// **Not an http link, deliberately.** The obvious alternative is
/// `https://host/channels/x/messages/y`, and it is the wrong shape for the same
/// reason an invite is not one (see `docs/OPEN-QUESTIONS.md` item 21): there is
/// nothing hosting a web page at that address, so an https link would look
/// clickable and open a 404.
///
/// **And it is never opened through `launchUrl`.** `message_inline.dart` matches
/// only http and https for a tappable link, and `message_text.dart` re-checks
/// the scheme before opening one, precisely so nothing can smuggle an app scheme
/// past the opener. A message link is recognised separately and navigated
/// *inside* the app instead, so that guard stays exactly as tight as it was: the
/// worst a hostile `slimm://message` link can do is ask this app to scroll to a
/// message id in a channel the reader can already see.
library;

import 'link_query.dart';

const _scheme = 'slimm';
const _host = 'message';

/// What a message link points at.
typedef MessageLink = ({Uri server, String channelId, String messageId});

/// Builds the link for [messageId] in [channelId] on [server].
String buildMessageLink({
  required Uri server,
  required String channelId,
  required String messageId,
}) => Uri(
  scheme: _scheme,
  host: _host,
  queryParameters: {
    'server': server.toString(),
    'channel': channelId,
    'id': messageId,
  },
).toString();

/// What [text] points at, or null if it is not a message link.
///
/// Null covers every kind of not-a-link for the same reason `parseInviteLink`'s
/// does: the caller's response to a bare word, a web address and an empty paste
/// is identical, and there is nothing here an error message could usefully tell
/// them apart for.
MessageLink? parseMessageLink(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || uri.scheme != _scheme || uri.host != _host) return null;

  final query = queryOrNull(uri);
  if (query == null) return null;
  final rawServer = query['server']?.trim() ?? '';
  final channelId = query['channel']?.trim() ?? '';
  final messageId = query['id']?.trim() ?? '';
  if (rawServer.isEmpty || channelId.isEmpty || messageId.isEmpty) return null;

  final server = Uri.tryParse(rawServer);
  if (server == null || !server.hasScheme || server.host.isEmpty) return null;

  return (server: server, channelId: channelId, messageId: messageId);
}

/// Whether [link] names the deployment this client is signed into.
///
/// A link to somewhere else is not followed, and that is the same call
/// `deep_links.dart` already makes about an invite arriving while signed in: one
/// deployment is one community in v1, so following a link to another server is a
/// server switch, which is a product decision a tapped link has no standing to
/// make.
///
/// Compared on scheme, host and port rather than the whole string, so a trailing
/// slash or a default port written out does not make a link to this very server
/// look foreign.
bool messageLinkIsHere(MessageLink link, Uri signedInTo) {
  final a = link.server;
  final b = signedInTo;
  return a.scheme == b.scheme &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      _port(a) == _port(b);
}

int _port(Uri uri) {
  if (uri.hasPort) return uri.port;
  return uri.scheme == 'http' ? 80 : 443;
}
