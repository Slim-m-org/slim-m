// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What `GET /roles/{id}/preview` answers: the server as one role sees it.
library;

import 'models_channel.dart';

/// The categories and channels a member holding only `@everyone` and one role is listed.
class RolePreview {
  const RolePreview({
    required this.roleId,
    required this.permissions,
    required this.categories,
    required this.channels,
  });

  final String roleId;

  /// The deployment-level grant of `@everyone` plus this role.
  final int permissions;
  final List<ChannelCategory> categories;
  final List<RolePreviewChannel> channels;

  factory RolePreview.fromJson(Map<String, dynamic> json) => RolePreview(
        roleId: json['role_id'] as String,
        permissions: json['permissions'] as int,
        categories: (json['categories'] as List<dynamic>)
            .map((c) => ChannelCategory.fromJson(c as Map<String, dynamic>))
            .toList(growable: false),
        channels: (json['channels'] as List<dynamic>)
            .map((c) => RolePreviewChannel.fromJson(c as Map<String, dynamic>))
            .toList(growable: false),
      );
}

/// One channel in a [RolePreview], with the role's effective bits there.
class RolePreviewChannel {
  const RolePreviewChannel({
    required this.id,
    required this.name,
    required this.kind,
    required this.position,
    required this.permissions,
    required this.restricted,
    this.categoryId,
  });

  final String id;
  final String name;

  /// `text` or `voice`.
  final String kind;
  final int position;
  final String? categoryId;
  final int permissions;

  /// Whether `@everyone` itself lacks view here.
  final bool restricted;

  bool get isVoice => kind == 'voice';

  factory RolePreviewChannel.fromJson(Map<String, dynamic> json) =>
      RolePreviewChannel(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: json['kind'] as String,
        position: json['position'] as int,
        categoryId: json['category_id'] as String?,
        permissions: json['permissions'] as int,
        restricted: json['restricted'] as bool,
      );
}
