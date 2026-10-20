// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which bot mentions have shown their help card this message, and which
/// cards are still on screen.
library;

class ComposerMentionHelp {
  /// Bot usernames whose card has been shown or dismissed this message, so
  /// retyping the same `@mention` never re-triggers it.
  final Set<String> _seen = {};
  final List<String> _visible = [];

  List<String> get visible => _visible;

  /// The usernames in [mentioned] not yet shown this message.
  List<String> unseen(Iterable<String> mentioned) =>
      mentioned.toSet().difference(_seen).toList();

  void show(List<String> usernames) {
    _seen.addAll(usernames);
    _visible.addAll(usernames);
  }

  void dismiss(String username) => _visible.remove(username);

  void clear() {
    _seen.clear();
    _visible.clear();
  }
}
