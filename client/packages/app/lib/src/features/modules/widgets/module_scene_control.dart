// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a scene offers under the board: a button, or one choice of several.
library;

import 'package:flutter/foundation.dart';

/// One entry of a scene's `controls`.
sealed class SceneControl {
  const SceneControl();
}

/// A button that sends its own [name] as the action.
@immutable
class SceneButton extends SceneControl {
  const SceneButton(this.name);

  final String name;

  @override
  bool operator ==(Object other) => other is SceneButton && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'SceneButton($name)';
}

/// A dropdown showing [value]; picking another of [options] sends that option
/// as the action, exactly as a button of that name would.
@immutable
class SceneSelect extends SceneControl {
  const SceneSelect({required this.label, required this.options, this.value});

  /// What the choice is about ("board size"), for a screen reader and the
  /// phone sheet's heading.
  final String label;
  final List<String> options;

  /// The option in force, or null when none of [options] is.
  final String? value;

  /// The most options one dropdown may carry.
  static const maxOptions = 16;

  @override
  bool operator ==(Object other) =>
      other is SceneSelect &&
      other.label == label &&
      other.value == value &&
      listEquals(other.options, options);

  @override
  int get hashCode => Object.hash(label, value, Object.hashAll(options));

  @override
  String toString() => 'SceneSelect($label: $value of $options)';
}

/// Reads a scene's `controls`: a string is a button, an object with `options`
/// a dropdown, and anything else is skipped.
///
/// A dropdown's `replaces` names the buttons an older client, which skips the
/// dropdown, shows in its place; this client leaves those buttons out while
/// the dropdown itself fits under [limit].
List<SceneControl> parseSceneControls(Object? raw, {required int limit}) {
  if (raw is! List) return const [];
  final entries = [for (final entry in raw) ?_entry(entry)];
  final hidden = {for (final entry in entries) ...entry.replaces};
  return List.unmodifiable([
    for (final entry in _fit(entries, hidden, limit)) entry.control,
  ]);
}

typedef _Entry = ({SceneControl control, Set<String> replaces});

_Entry? _entry(Object? raw) {
  if (raw is String) return (control: SceneButton(raw), replaces: const {});
  if (raw is! Map<Object?, Object?>) return null;
  final select = _select(raw);
  if (select == null) return null;
  final names = raw['replaces'];
  return (
    control: select,
    replaces: names is List ? names.whereType<String>().toSet() : const {},
  );
}

/// The first [limit] entries, without the buttons a shown dropdown replaces.
List<_Entry> _fit(List<_Entry> entries, Set<String> hidden, int limit) {
  final shown = entries
      .where(
        (entry) => switch (entry.control) {
          SceneButton(:final name) => !hidden.contains(name),
          SceneSelect() => true,
        },
      )
      .take(limit)
      .toList();
  final stillHidden = {for (final entry in shown) ...entry.replaces};
  // A cut dropdown's buttons come back and can push a later dropdown out too.
  return setEquals(stillHidden, hidden)
      ? shown
      : _fit(entries, stillHidden, limit);
}

SceneSelect? _select(Map<Object?, Object?> raw) {
  final options = raw['options'];
  if (options is! List) return null;
  final names = options
      .whereType<String>()
      .where((o) => o.trim().isNotEmpty)
      .toSet()
      .take(SceneSelect.maxOptions)
      .toList(growable: false);
  if (names.isEmpty) return null;
  final value = raw['value'];
  final label = raw['label'];
  return SceneSelect(
    label: label is String && label.trim().isNotEmpty ? label : 'choose',
    options: names,
    value: value is String && names.contains(value) ? value : null,
  );
}
