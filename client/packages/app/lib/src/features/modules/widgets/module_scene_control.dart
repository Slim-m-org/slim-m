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
/// dropdown, shows in its place; this client leaves those buttons out.
List<SceneControl> parseSceneControls(Object? raw, {required int limit}) {
  if (raw is! List) return const [];
  final replaced = {
    for (final entry in raw.whereType<Map<Object?, Object?>>())
      if ((entry['replaces'], _select(entry)) case (
        final List<Object?> names,
        _?,
      ))
        ...names.whereType<String>(),
  };
  final controls = <SceneControl>[];
  for (final entry in raw) {
    if (controls.length >= limit) break;
    final control = switch (entry) {
      String name when replaced.contains(name) => null,
      String name => SceneButton(name),
      Map<Object?, Object?> select => _select(select),
      _ => null,
    };
    if (control != null) controls.add(control);
  }
  return List.unmodifiable(controls);
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
