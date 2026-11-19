// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Spotify HTTP client on the web, where the browser checks certificates.
library;

import 'package:http/http.dart' as http;

http.Client spotifyHttpClient() => http.Client();
