// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sends an upload body, reporting what the network has taken so far.
library;

export 'upload_send_web.dart' if (dart.library.io) 'upload_send_io.dart';
