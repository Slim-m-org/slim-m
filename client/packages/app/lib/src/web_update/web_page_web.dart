// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser half of `web_page.dart`.
///
/// `version.json` is resolved against the document's `<base href>`, not
/// `Uri.base`: under path routing the latter is the current route, and
/// `channels/version.json` is not where the image serves it.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

Future<String?> fetchLiveWebBuild() async {
  try {
    final url = Uri.parse(
      web.document.baseURI,
    ).resolve('version.json?t=${DateTime.now().millisecondsSinceEpoch}');
    final res = await http
        .get(url, headers: const {'cache-control': 'no-cache'})
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body);
    final build = body is Map ? body['build'] : null;
    return build is String && build.isNotEmpty ? build : null;
  } on Object catch (error, stack) {
    AppLog.swallowed(
      LogTag.platform,
      'Could not check for a newer web build',
      error,
      stack,
    );
    // A failed poll is silence; the next tick or tab focus tries again.
    return null;
  }
}

void reloadPage() => web.window.location.reload();
