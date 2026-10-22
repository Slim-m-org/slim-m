// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The module that posted a message, written by the host and never by the module.
///
/// Split out of models.dart purely to stay under this repo's line budget.
library;

/// Attached to a [Message] as `viaModule`. Null on every message no module
/// posted; fixed once the message exists.
class ViaModule {
  const ViaModule({
    required this.id,
    required this.name,
    required this.background,
  });

  final String id;
  final String name;

  /// True when nobody ran the module: it posted as itself on its own timer.
  final bool background;

  factory ViaModule.fromJson(Map<String, dynamic> json) => ViaModule(
        id: json['id'] as String,
        name: json['name'] as String,
        background: json['background'] as bool,
      );
}
