// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one place a tapped link leaves the app for the system browser.
///
/// Only a plain http or https URL gets out. A scheme that would open another
/// app (`intent:`, `file:`, `mailto:`, an app scheme) is refused here so a
/// change to that policy is made once, not in every widget that has a link.
library;

import 'package:url_launcher/url_launcher.dart';

/// What [openExternalHttpUrl] hands a URL to; [launchUrl] in the app.
typedef ExternalUrlLauncher = Future<bool> Function(Uri url, {LaunchMode mode});

/// Opens [rawUrl] outside the app if it is http or https, and ignores
/// anything else, including a string that does not parse.
Future<void> openExternalHttpUrl(
  String rawUrl, {
  ExternalUrlLauncher launcher = launchUrl,
}) async {
  final uri = Uri.tryParse(rawUrl);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return;
  await launcher(uri, mode: LaunchMode.externalApplication);
}
