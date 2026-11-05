// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The web stand-in for `kwin_keep_above.dart`: a browser has no KWin.
library;

String keepAboveScript({required int pid, required String caption}) => '';

Future<bool> kwinKeepAbove(String caption) async => false;
