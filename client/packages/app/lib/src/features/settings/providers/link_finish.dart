// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Finishing an account link in the app with the handoff code the browser page
/// shows. It arrives as a tapped link, a web redirect or a paste; the server
/// links only for the account that started the link. Discord and Steam share it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../api_failure.dart';
import '../../../link_query.dart';

/// The query key the `slimm://` and web forms carry the code under.
const linkCodeQuery = 'code';

const _maxCodeChars = 64;

/// The server's refusal of a code, the same wording for every service.
const linkCodeRefused =
    'That code did not work. It may have expired, or belong to another account.';

/// The code in [raw], which may be the whole link, or a code with dashes,
/// spaces or lower case from being read off the page; null when none is there.
String? parseLinkCode(String raw) {
  final trimmed = raw.trim();
  final parsed = Uri.tryParse(trimmed);
  if (parsed != null && parsed.hasQuery && queryOrNull(parsed) == null) {
    return null;
  }
  final linked = parsed == null ? null : queryParam(parsed, linkCodeQuery);
  final code = (linked ?? trimmed).toUpperCase().replaceAll(
    RegExp('[^A-Z0-9]'),
    '',
  );
  return code.isEmpty || code.length > _maxCodeChars ? null : code;
}

/// Why a link did not finish; [aboutCode] when the code itself was the problem.
class LinkFailure {
  const LinkFailure(this.message, {this.aboutCode = false});

  final String message;
  final bool aboutCode;
}

/// Where finishing a link stands, for the Connections section to show.
sealed class LinkStatus {
  const LinkStatus();
}

class LinkIdle extends LinkStatus {
  const LinkIdle();
}

class LinkFinishing extends LinkStatus {
  const LinkFinishing();
}

/// The attempt ended without a link; [message] stays until dismissed.
class LinkFailed extends LinkStatus {
  const LinkFailed(this.message);

  final String message;
}

class LinkStatusController extends Notifier<LinkStatus> {
  @override
  LinkStatus build() => const LinkIdle();

  void set(LinkStatus next) => state = next;
}

class LinkFinisher {
  LinkFinisher({
    required this.service,
    required this.completeLink,
    required this.status,
    required this.onLinked,
  });

  /// The service's display name, for the sentences shown to the person.
  final String service;

  /// Sends the cleaned code to the server.
  final Future<void> Function(String code) completeLink;
  final LinkStatusController status;
  final void Function() onLinked;
  String? _lastDelivered;
  bool _closed = false;

  void close() => _closed = true;

  /// Links with [raw], answering why it did not work, or null once it did.
  Future<LinkFailure?> complete(String raw) async {
    final code = parseLinkCode(raw);
    if (code == null) {
      return LinkFailure(
        'Paste the code from the $service page.',
        aboutCode: true,
      );
    }
    try {
      await completeLink(code);
      if (!_closed) {
        onLinked();
        status.set(const LinkIdle());
      }
      return null;
    } on api.NotFoundException {
      return const LinkFailure(linkCodeRefused, aboutCode: true);
    } on api.ApiException catch (error, stack) {
      return LinkFailure(
        reportFailureSentence(
          api.LogTag.ui,
          'finish linking $service',
          error,
          stack,
        ),
      );
    }
  }

  /// [complete] for a code that arrived as a link, reporting through [status].
  /// A code already handled is ignored, but one that failed for a reason other
  /// than the code can be delivered again.
  Future<void> completeDelivered(String raw) async {
    final code = parseLinkCode(raw);
    if (code == null || code == _lastDelivered) return;
    _lastDelivered = code;
    status.set(const LinkFinishing());
    final failure = await complete(code);
    if (_closed) return;
    if (failure == null) return;
    if (!failure.aboutCode) _lastDelivered = null;
    status.set(LinkFailed(failure.message));
  }
}
