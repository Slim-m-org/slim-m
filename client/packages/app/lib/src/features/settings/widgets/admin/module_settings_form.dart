// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The form a module's declared settings generate
/// (docs/decisions/0091-module-platform-phase-1-contracts.md, "Settings").
/// Edits stay local until Save, and only what changed is sent.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../settings_info_line.dart';
import '../settings_save_bar.dart';
import '../settings_section_header.dart';
import '../settings_select_row.dart';
import '../settings_slider_row.dart';
import '../settings_toggle_row.dart';
import 'module_setting_fields.dart';

/// Sends the changed values; a null value clears that setting.
typedef ModuleSettingsSave = Future<void> Function(Map<String, Object?> values);

class ModuleSettingsForm extends StatefulWidget {
  const ModuleSettingsForm({
    super.key,
    required this.doc,
    required this.onSave,
    this.saving = false,
    this.error,
    this.onDismissError,
  });

  final api.ModuleSettingsDoc doc;
  final ModuleSettingsSave onSave;
  final bool saving;

  /// A failed save, shown under the form while the edits stay put.
  final String? error;
  final VoidCallback? onDismissError;

  @override
  State<ModuleSettingsForm> createState() => _ModuleSettingsFormState();
}

class _ModuleSettingsFormState extends State<ModuleSettingsForm> {
  final _values = <String, Object?>{};
  final _controllers = <String, TextEditingController>{};
  final _cleared = <String>{};
  String? _invalid;

  @override
  void initState() {
    super.initState();
    for (final e in widget.doc.settings) {
      _seed(e);
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  static Object? _original(api.ModuleSettingEntry e) =>
      e.value ?? e.def.defaultValue;

  static bool _bounded(api.ModuleSettingDef d) =>
      d.min != null && d.max != null && d.max! > d.min!;

  void _seed(api.ModuleSettingEntry e) {
    final key = e.def.key;
    final original = _original(e);
    switch (e.def.type) {
      case api.ModuleSettingType.boolean:
        _values[key] = original == true;
      case api.ModuleSettingType.integer when _bounded(e.def):
        final start = original is num ? original.round() : e.def.min!;
        _values[key] = start.clamp(e.def.min!, e.def.max!);
      case api.ModuleSettingType.integer:
        _controllers[key] = TextEditingController(
          text: original is num ? '${original.round()}' : '',
        );
      case api.ModuleSettingType.string:
        _controllers[key] = TextEditingController(
          text: original is String ? original : '',
        );
      case api.ModuleSettingType.choice:
        _values[key] = original is String ? original : null;
      case api.ModuleSettingType.secret:
        _controllers[key] = TextEditingController();
      case api.ModuleSettingType.unknown:
        break;
    }
  }

  /// The key's new value when it differs from what is stored, else absent.
  Map<String, Object?> _changes() {
    final out = <String, Object?>{};
    for (final e in widget.doc.settings) {
      final key = e.def.key;
      final original = _original(e);
      final text = _controllers[key]?.text ?? '';
      switch (e.def.type) {
        case api.ModuleSettingType.boolean:
          if (_values[key] != (original == true)) out[key] = _values[key];
        case api.ModuleSettingType.integer when _bounded(e.def):
          final was = original is num ? original.round() : null;
          if (_values[key] != (was ?? e.def.min)) out[key] = _values[key];
        case api.ModuleSettingType.integer:
          final was = original is num ? '${original.round()}' : '';
          if (text.trim() != was) out[key] = int.tryParse(text.trim());
        case api.ModuleSettingType.string:
          if (text != (original is String ? original : '')) {
            // Empty text drops the stored value, back to the default.
            out[key] = text.isEmpty ? null : text;
          }
        case api.ModuleSettingType.choice:
          if (_values[key] != (original is String ? original : null)) {
            out[key] = _values[key];
          }
        case api.ModuleSettingType.secret:
          if (_cleared.contains(key)) {
            out[key] = null;
          } else if (text.isNotEmpty) {
            out[key] = text;
          }
        case api.ModuleSettingType.unknown:
          break;
      }
    }
    return out;
  }

  String? _problem(Map<String, Object?> changes) {
    for (final e in widget.doc.settings) {
      final d = e.def;
      if (d.type != api.ModuleSettingType.integer || _bounded(d)) continue;
      if (!changes.containsKey(d.key)) continue;
      final value = changes[d.key];
      if (value == null) return '${d.label} needs a whole number.';
      if (value is int && d.min != null && value < d.min!) {
        return '${d.label} must be at least ${d.min}.';
      }
      if (value is int && d.max != null && value > d.max!) {
        return '${d.label} must be at most ${d.max}.';
      }
    }
    return null;
  }

  Future<void> _save() async {
    final changes = _changes();
    final problem = _problem(changes);
    setState(() => _invalid = problem);
    if (problem != null) return;
    await widget.onSave(changes);
  }

  void _discard() => setState(() {
    _invalid = null;
    _cleared.clear();
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    _values.clear();
    for (final e in widget.doc.settings) {
      _seed(e);
    }
  });

  @override
  Widget build(BuildContext context) {
    final count = _changes().length;
    final message = _invalid ?? widget.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Settings',
          children: [for (final e in widget.doc.settings) _row(e)],
        ),
        if (message != null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(
            message: message,
            onDismiss: _invalid != null
                ? () => setState(() => _invalid = null)
                : widget.onDismissError,
          ),
        ],
        if (count > 0) ...[
          const SizedBox(height: AppSpacing.s8),
          SettingsSaveBar(
            changeCount: count,
            saving: widget.saving,
            onDiscard: _discard,
            onSave: _save,
          ),
        ],
      ],
    );
  }

  Widget _row(api.ModuleSettingEntry e) {
    final d = e.def;
    final key = d.key;
    void changed() => setState(() {});
    return switch (d.type) {
      api.ModuleSettingType.boolean => SettingsToggleRow(
        label: d.label,
        description: d.help,
        value: _values[key] == true,
        onChanged: (v) => setState(() => _values[key] = v),
        semanticLabel: d.label,
      ),
      api.ModuleSettingType.choice => SettingsSelectRow<String>(
        label: d.label,
        description: d.help,
        value: _values[key] as String?,
        choices: [
          for (final c in d.choices)
            SettingsChoice(value: c.value, label: c.label),
        ],
        onChanged: (v) => setState(() => _values[key] = v),
      ),
      api.ModuleSettingType.integer when _bounded(d) => _slider(d),
      api.ModuleSettingType.integer => ModuleSettingNumberField(
        label: d.label,
        help: d.help,
        controller: _controllers[key]!,
        onChanged: changed,
      ),
      api.ModuleSettingType.string => ModuleSettingTextField(
        label: d.label,
        help: d.help,
        controller: _controllers[key]!,
        onChanged: changed,
      ),
      api.ModuleSettingType.secret => ModuleSettingSecretField(
        label: d.label,
        help: d.help,
        controller: _controllers[key]!,
        stored: e.secretSet,
        cleared: _cleared.contains(key),
        onChanged: changed,
        onClearToggle: () => setState(() {
          _controllers[key]!.clear();
          if (!_cleared.remove(key)) _cleared.add(key);
        }),
      ),
      api.ModuleSettingType.unknown => SettingsInfoLine(
        '${d.label} cannot be edited in this version.',
      ),
    };
  }

  Widget _slider(api.ModuleSettingDef d) {
    final min = d.min!;
    final max = d.max!;
    final value = (_values[d.key] as int).clamp(min, max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSliderRow(
          label: d.label,
          valueLabel: '$value',
          value: value.toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          minLabel: '$min',
          maxLabel: '$max',
          divisions: max > min && max - min <= 100 ? max - min : null,
          onChanged: (v) => setState(() => _values[d.key] = v.round()),
        ),
        if (d.help case final help?) SettingsInfoLine(help),
      ],
    );
  }
}
