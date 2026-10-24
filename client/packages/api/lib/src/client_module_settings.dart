// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// An installed module's settings. Both routes require MANAGE_SERVER.
extension SlimmApiModuleSettings on SlimmApi {
  Future<ModuleSettingsDoc> moduleSettings(String moduleId) async {
    final json = await _send('GET', '/space/dock/modules/$moduleId/settings');
    return ModuleSettingsDoc.fromJson(json);
  }

  /// Saves [values] together or not at all; a null value clears that setting.
  /// Answers the settings as they are afterwards.
  Future<ModuleSettingsDoc> saveModuleSettings(
    String moduleId,
    Map<String, Object?> values,
  ) async {
    final json = await _send(
      'PUT',
      '/space/dock/modules/$moduleId/settings',
      body: {'values': values},
    );
    return ModuleSettingsDoc.fromJson(json);
  }
}
