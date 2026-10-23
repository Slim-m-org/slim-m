// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The text-entry rows of a module's generated settings form: a whole number
/// with no bounds, a plain string, and a secret that is never shown back.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

import '../settings_field.dart';
import '../settings_section_header.dart';

/// A whole number for a setting that has no range to drag across.
class ModuleSettingNumberField extends StatelessWidget {
  const ModuleSettingNumberField({
    super.key,
    required this.label,
    required this.controller,
    required this.onChanged,
    this.help,
  });

  final String label;
  final String? help;
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => SettingsCardBlock(
    children: [
      SettingsField(
        label: label,
        helper: help,
        child: AppInput(
          controller: controller,
          mono: true,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp('[-0-9]')),
          ],
          onChanged: (_) => onChanged(),
          semanticLabel: label,
        ),
      ),
    ],
  );
}

class ModuleSettingTextField extends StatelessWidget {
  const ModuleSettingTextField({
    super.key,
    required this.label,
    required this.controller,
    required this.onChanged,
    this.help,
  });

  final String label;
  final String? help;
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => SettingsCardBlock(
    children: [
      SettingsField(
        label: label,
        helper: help,
        child: AppInput(
          controller: controller,
          onChanged: (_) => onChanged(),
          semanticLabel: label,
        ),
      ),
    ],
  );
}

/// A masked input. A stored secret is only ever described as "Set"; typing
/// replaces it and Clear removes it on the next save.
class ModuleSettingSecretField extends StatelessWidget {
  const ModuleSettingSecretField({
    super.key,
    required this.label,
    required this.controller,
    required this.stored,
    required this.cleared,
    required this.onChanged,
    required this.onClearToggle,
    this.help,
  });

  final String label;
  final String? help;
  final TextEditingController controller;

  /// Whether the server holds a value for it.
  final bool stored;
  final bool cleared;
  final VoidCallback onChanged;
  final VoidCallback onClearToggle;

  @override
  Widget build(BuildContext context) {
    final removable = stored && (cleared || controller.text.isEmpty);
    return SettingsCardBlock(
      children: [
        SettingsField(
          label: label,
          helper: help,
          child: AppInput(
            controller: controller,
            obscureText: true,
            enabled: !cleared,
            autocorrect: false,
            placeholder: cleared
                ? 'Will be cleared'
                : stored
                ? 'Set'
                : 'Not set',
            trailing: removable
                ? AppButton(
                    label: cleared ? 'Undo' : 'Clear',
                    variant: AppButtonVariant.ghost,
                    size: AppButtonSize.sm,
                    onPressed: onClearToggle,
                  )
                : null,
            onChanged: (_) => onChanged(),
            semanticLabel: label,
          ),
        ),
      ],
    );
  }
}
