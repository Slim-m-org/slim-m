// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Buttons and select menus a bot attaches to its own message. See
/// docs/decisions/0039-bot-message-buttons.md and
/// docs/decisions/0082-bot-token-reissue-select-menus-and-forms.md.
library;

enum ComponentButtonStyle {
  primary,
  secondary,
  danger,
  link;

  /// An unrecognised style from a newer server reads as [secondary], so the
  /// button still renders and can still be pressed.
  static ComponentButtonStyle fromWire(String? value) => switch (value) {
        'primary' => primary,
        'danger' => danger,
        'link' => link,
        _ => secondary,
      };
}

class MessageButton {
  const MessageButton({
    required this.label,
    required this.style,
    this.customId,
    this.url,
    this.disabled = false,
  });

  final String label;
  final ComponentButtonStyle style;

  /// Null on a link button, which never reaches the bot.
  final String? customId;

  /// Set only on a link button.
  final String? url;
  final bool disabled;

  factory MessageButton.fromJson(Map<String, dynamic> json) => MessageButton(
        label: json['label'] as String,
        style: ComponentButtonStyle.fromWire(json['style'] as String?),
        customId: json['custom_id'] as String?,
        url: json['url'] as String?,
        disabled: json['disabled'] as bool? ?? false,
      );
}

class SelectChoice {
  const SelectChoice({
    required this.label,
    required this.value,
    this.description,
  });

  final String label;

  /// What the bot receives when this choice is made.
  final String value;
  final String? description;

  factory SelectChoice.fromJson(Map<String, dynamic> json) => SelectChoice(
        label: json['label'] as String,
        value: json['value'] as String,
        description: json['description'] as String?,
      );
}

class MessageSelect {
  const MessageSelect({
    required this.customId,
    required this.options,
    this.placeholder,
    this.minValues = 1,
    this.maxValues = 1,
    this.disabled = false,
  });

  final String customId;
  final String? placeholder;
  final List<SelectChoice> options;

  /// Zero lets a member choose nothing.
  final int minValues;
  final int maxValues;
  final bool disabled;

  /// A single pick from a short list, which answers the moment it is chosen.
  bool get picksOne => maxValues == 1 && minValues == 1;

  factory MessageSelect.fromJson(Map<String, dynamic> json) => MessageSelect(
        customId: json['custom_id'] as String,
        placeholder: json['placeholder'] as String?,
        options: (json['options'] as List<dynamic>)
            .map((o) => SelectChoice.fromJson(o as Map<String, dynamic>))
            .toList(growable: false),
        minValues: json['min_values'] as int? ?? 1,
        maxValues: json['max_values'] as int? ?? 1,
        disabled: json['disabled'] as bool? ?? false,
      );
}

/// One row: up to five buttons, or a single select menu.
class ComponentRow {
  const ComponentRow({this.buttons = const [], this.select});

  final List<MessageButton> buttons;
  final MessageSelect? select;

  factory ComponentRow.fromJson(Map<String, dynamic> json) => ComponentRow(
        buttons: (json['buttons'] as List<dynamic>? ?? const [])
            .map((b) => MessageButton.fromJson(b as Map<String, dynamic>))
            .toList(growable: false),
        select: switch (json['select']) {
          final Map<String, dynamic> select => MessageSelect.fromJson(select),
          _ => null,
        },
      );

  static List<ComponentRow> listFromJson(Object? json) =>
      (json as List<dynamic>?)
          ?.map((r) => ComponentRow.fromJson(r as Map<String, dynamic>))
          .toList(growable: false) ??
      const [];
}
