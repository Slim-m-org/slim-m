// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module's declared settings and their current values, per
/// `docs/decisions/0091-module-platform-phase-1-contracts.md`.
library;

enum ModuleSettingType {
  boolean,
  integer,
  string,
  choice,
  secret,

  /// A type this client does not know; the form leaves the setting out.
  unknown;

  String get wire => switch (this) {
        ModuleSettingType.boolean => 'bool',
        ModuleSettingType.integer => 'int',
        ModuleSettingType.unknown => 'unknown',
        _ => name,
      };

  static ModuleSettingType parse(Object? value) => switch (value) {
        'bool' => ModuleSettingType.boolean,
        'int' => ModuleSettingType.integer,
        'string' => ModuleSettingType.string,
        'choice' => ModuleSettingType.choice,
        'secret' => ModuleSettingType.secret,
        _ => ModuleSettingType.unknown,
      };
}

class ModuleSettingChoice {
  const ModuleSettingChoice({required this.value, required this.label});

  final String value;
  final String label;

  static ModuleSettingChoice? tryParse(Object? json) {
    if (json is! Map) return null;
    final value = json['value'];
    if (value is! String) return null;
    final label = json['label'];
    return ModuleSettingChoice(
      value: value,
      label: label is String ? label : value,
    );
  }
}

class ModuleSettingDef {
  const ModuleSettingDef({
    required this.key,
    required this.type,
    required this.label,
    this.help,
    this.defaultValue,
    this.min,
    this.max,
    this.choices = const [],
  });

  final String key;
  final ModuleSettingType type;
  final String label;
  final String? help;
  final Object? defaultValue;
  final int? min;
  final int? max;
  final List<ModuleSettingChoice> choices;

  static ModuleSettingDef? tryParse(Object? json) {
    if (json is! Map) return null;
    final key = json['key'];
    if (key is! String || key.isEmpty) return null;
    final label = json['label'];
    final help = json['help'];
    final min = json['min'];
    final max = json['max'];
    final choices = json['choices'];
    return ModuleSettingDef(
      key: key,
      type: ModuleSettingType.parse(json['type']),
      label: label is String ? label : key,
      help: help is String ? help : null,
      defaultValue: json['default'],
      min: min is int ? min : null,
      max: max is int ? max : null,
      choices: choices is List
          ? choices
              .map(ModuleSettingChoice.tryParse)
              .whereType<ModuleSettingChoice>()
              .toList(growable: false)
          : const [],
    );
  }
}

/// One setting with what it is now. For a secret [value] is always null and
/// only [secretSet] says whether one is stored.
class ModuleSettingEntry {
  const ModuleSettingEntry({
    required this.def,
    this.value,
    this.secretSet = false,
  });

  final ModuleSettingDef def;
  final Object? value;
  final bool secretSet;

  static ModuleSettingEntry? tryParse(Object? json) {
    final def = ModuleSettingDef.tryParse(json);
    if (def == null || json is! Map) return null;
    final value = json['value'];
    if (def.type == ModuleSettingType.secret) {
      return ModuleSettingEntry(
        def: def,
        secretSet: value is Map && value['set'] == true,
      );
    }
    return ModuleSettingEntry(def: def, value: value);
  }
}

class ModuleSettingsDoc {
  const ModuleSettingsDoc(this.settings);

  final List<ModuleSettingEntry> settings;

  factory ModuleSettingsDoc.fromJson(Object? json) {
    final raw = json is Map ? json['settings'] : null;
    if (raw is! List) return const ModuleSettingsDoc([]);
    return ModuleSettingsDoc(
      raw
          .map(ModuleSettingEntry.tryParse)
          .whereType<ModuleSettingEntry>()
          .toList(growable: false),
    );
  }
}
