// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A segmented control's presets with the stored value added when it is not one of them.
///
/// The server accepts wider ranges than a control offers, so a value set elsewhere has to read as itself rather than as the first preset.
library;

List<(String, int)> presetsIncluding(
  List<(String, int)> presets,
  int current,
  String Function(int) label,
) {
  if (presets.any((o) => o.$2 == current)) return presets;
  final options = [...presets, (label(current), current)];
  options.sort((a, b) => a.$2.compareTo(b.$2));
  return options;
}
