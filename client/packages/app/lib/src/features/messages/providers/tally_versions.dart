// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The newest live tally version seen per message, so a frame that arrives
/// after a newer one for the same message is ignored.
library;

class TallyVersions {
  final _newest = <String, int>{};

  /// Whether a frame for [messageId] at [version] should apply, recording it
  /// when it does. A frame without a version, from an older server, always applies.
  bool isNewer(String messageId, int? version) {
    if (version == null) return true;
    final held = _newest[messageId];
    if (held != null && version <= held) return false;
    _newest[messageId] = version;
    return true;
  }

  void retainWhere(bool Function(String messageId) keep) =>
      _newest.removeWhere((id, _) => !keep(id));

  void clear() => _newest.clear();
}
