// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Spotify HTTP client off the web; see [RootFetchingClient] for Windows.
library;

import 'package:http/http.dart' as http;
import 'package:slimm_platform/platform.dart' show isWindowsHost;

import 'root_fetching_client.dart';
import 'windows_root_fetch.dart';

http.Client spotifyHttpClient() => isWindowsHost
    ? RootFetchingClient(fetchRoots: fetchWindowsRootsFor)
    : http.Client();
