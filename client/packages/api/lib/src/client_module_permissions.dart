// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// The dynamic half of the permission model (docs/decisions/0021): the
/// grantable rows a module registers on install, alongside the fixed
/// bitmask `SlimmApiRoles` carries. Every call here requires MANAGE_ROLES,
/// the same bit a core permission grant needs, since granting one is a
/// role-management act rather than a Dock one.
extension SlimmApiModulePermissions on SlimmApi {
  /// Every module-scoped permission any installed module currently declares,
  /// independent of any one role.
  Future<List<ModulePermission>> listModulePermissions() async {
    final json = await send('GET', '/roles/module-permissions');
    return (json as List<dynamic>)
        .map((p) => ModulePermission.fromJson(p as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// The module permissions [roleId] currently holds.
  Future<List<GrantedModulePermission>> listRoleModulePermissions(
    String roleId,
  ) async {
    final json = await send('GET', '/roles/$roleId/module-permissions');
    return (json as List<dynamic>)
        .map((p) => GrantedModulePermission.fromJson(p as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Grants a module permission to a role. Idempotent. Refused with 404 if
  /// no installed module currently declares `(moduleId, permKey)`.
  Future<void> grantModulePermission({
    required String roleId,
    required String moduleId,
    required String permKey,
  }) =>
      send(
        'PUT',
        '/roles/$roleId/module-permissions/$moduleId/$permKey',
        expectNoContent: true,
      );

  /// Revokes a module permission from a role. Idempotent: revoking one not
  /// held still succeeds.
  Future<void> revokeModulePermission({
    required String roleId,
    required String moduleId,
    required String permKey,
  }) =>
      send(
        'DELETE',
        '/roles/$roleId/module-permissions/$moduleId/$permKey',
        expectNoContent: true,
      );
}
