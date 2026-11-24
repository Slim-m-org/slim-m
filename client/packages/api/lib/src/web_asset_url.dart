// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the web client fetches its lazily loaded assets from.
library;

const _webBuild = String.fromEnvironment('SLIMM_WEB_BUILD');

/// [path] keyed on the build id, so a tab never reuses another build's cached copy of it.
String versionedWebAssetUrl(String path, {String build = _webBuild}) =>
    build.isEmpty ? path : '$path?v=${Uri.encodeQueryComponent(build)}';
