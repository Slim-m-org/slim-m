// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared byte-size formatting for an attachment's caption, wherever it is
/// shown - the plain chip, an inline image, and the inline video player.
library;

/// `1.2 MB`-style formatting; short enough that this app has no existing
/// dependency worth using instead.
String formatByteSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
