// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A small form a bot opens for the member who pressed its button. See
/// docs/decisions/0083-bot-token-reissue-select-menus-and-forms.md.
library;

class BotFormField {
  const BotFormField({
    required this.customId,
    required this.label,
    this.placeholder,
    this.value,
    this.required = true,
    this.multiline = false,
    this.maxLength = 200,
  });

  final String customId;
  final String label;
  final String? placeholder;

  /// Prefilled text the member may change.
  final String? value;
  final bool required;
  final bool multiline;
  final int maxLength;

  factory BotFormField.fromJson(Map<String, dynamic> json) => BotFormField(
        customId: json['custom_id'] as String,
        label: json['label'] as String,
        placeholder: json['placeholder'] as String?,
        value: json['value'] as String?,
        required: json['required'] as bool? ?? true,
        multiline: json['multiline'] as bool? ?? false,
        maxLength: json['max_length'] as int? ?? 200,
      );
}

class BotForm {
  const BotForm({
    required this.customId,
    required this.title,
    required this.fields,
    this.submitLabel,
  });

  final String customId;
  final String title;
  final String? submitLabel;
  final List<BotFormField> fields;

  factory BotForm.fromJson(Map<String, dynamic> json) => BotForm(
        customId: json['custom_id'] as String,
        title: json['title'] as String,
        submitLabel: json['submit_label'] as String?,
        fields: (json['fields'] as List<dynamic>)
            .map((f) => BotFormField.fromJson(f as Map<String, dynamic>))
            .toList(growable: false),
      );
}
