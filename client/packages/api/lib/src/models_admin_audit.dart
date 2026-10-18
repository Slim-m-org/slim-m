// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `GET /space/audit-log`: one recorded admin change.
library;

/// One admin change, as the log records it. [id] is the paging cursor.
class AdminChange {
  const AdminChange({
    required this.id,
    required this.actorId,
    required this.action,
    required this.targetId,
    required this.detail,
    required this.createdAt,
  });

  final int id;

  /// Null once the actor's account is gone.
  final String? actorId;

  /// Dotted name such as `role.update`; an action this client has no wording
  /// for is still a valid row.
  final String action;
  final String? targetId;
  final Map<String, dynamic> detail;
  final int createdAt;

  factory AdminChange.fromJson(Map<String, dynamic> json) => AdminChange(
        id: json['id'] as int,
        actorId: json['actor_id'] as String?,
        action: json['action'] as String,
        targetId: json['target_id'] as String?,
        detail: (json['detail'] as Map<String, dynamic>?) ?? const {},
        createdAt: json['created_at'] as int,
      );

  /// Names of the request fields the change set, empty when none were logged.
  List<String> get fields => [
        for (final f in (detail['fields'] as List<dynamic>?) ?? const []) '$f',
      ];

  /// The name a create or rename set, when the log kept one.
  String? get name => detail['name'] as String?;

  /// A route id other than the target, such as `role_id` or `module_id`.
  String? param(String key) =>
      (detail['params'] as Map<String, dynamic>?)?[key] as String?;
}
