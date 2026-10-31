// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The account, space-setting, notification and sign-in writes the settings widgets make, so none of them talks to REST.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/providers.dart';

class SettingsActions {
  const SettingsActions(this._api);

  final SlimmApi _api;

  Future<Version> version() => _api.version();

  Future<TotpStatus> totpStatus() => _api.totpStatus();

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
    String? code,
  }) => _api.changePassword(
    currentPassword: currentPassword,
    newPassword: newPassword,
    code: code,
  );

  Future<void> deleteAccount({required String password, String? code}) =>
      _api.deleteAccount(password: password, code: code);

  Future<NotificationPreference> setNotificationPreference(
    NotificationPreference preference,
  ) => _api.setNotificationPreference(preference);

  Future<int?> setNotificationSnooze(int untilMs) =>
      _api.setNotificationSnooze(untilMs);

  Future<void> clearNotificationSnooze() => _api.clearNotificationSnooze();

  Future<NotificationSchedule> setNotificationSchedule({
    required String timezone,
    required OffHoursMode offHoursMode,
    required List<NotificationScheduleDay> days,
  }) => _api.setNotificationSchedule(
    timezone: timezone,
    offHoursMode: offHoursMode,
    days: days,
  );

  Future<void> clearNotificationSchedule() => _api.clearNotificationSchedule();

  Future<void> addNotificationScheduleAllowedUser(String userId) =>
      _api.addNotificationScheduleAllowedUser(userId);

  Future<void> removeNotificationScheduleAllowedUser(String userId) =>
      _api.removeNotificationScheduleAllowedUser(userId);

  Future<void> addNotificationScheduleAllowedChannel(String channelId) =>
      _api.addNotificationScheduleAllowedChannel(channelId);

  Future<void> removeNotificationScheduleAllowedChannel(String channelId) =>
      _api.removeNotificationScheduleAllowedChannel(channelId);

  Future<SpaceSettings> spaceSettings() => _api.spaceSettings();

  Future<SpaceSettings> setSpaceSettings(SpaceSettingsUpdate update) =>
      _api.setSpaceSettings(update);

  Future<JoinGate> setJoinGate(JoinGate gate) => _api.setJoinGate(gate);

  Future<void> acceptSpaceRules() => _api.acceptSpaceRules();

  Future<String> startDiscordLink() => _api.startDiscordLink();

  Future<void> unlinkDiscord() => _api.unlinkDiscord();

  Future<List<Device>> listDevices() => _api.listDevices();

  Future<void> removeDevice(String deviceId) => _api.removeDevice(deviceId);

  Future<void> deleteExport(String exportId) => _api.deleteExport(exportId);

  Future<DataExport> startSpaceExport({required String password}) =>
      _api.startSpaceExport(password: password);

  Future<DataExport> startMemberExport({required String password}) =>
      _api.startMemberExport(password: password);

  Future<TotpEnrolment> beginTotpEnrolment({required String password}) =>
      _api.beginTotpEnrolment(password: password);

  Future<List<String>> confirmTotpEnrolment(
    String code, {
    required String password,
  }) => _api.confirmTotpEnrolment(code, password: password);

  Future<List<String>> reissueTotpRecoveryCodes(String code) =>
      _api.reissueTotpRecoveryCodes(code);

  Future<void> disableTotp(String code) => _api.disableTotp(code);

  Future<TokenPair> verifyTotpChallenge({
    required String challenge,
    required String code,
    String? installId,
  }) => _api.verifyTotpChallenge(
    challenge: challenge,
    code: code,
    installId: installId,
  );

  Future<List<ChannelOverwrite>> syncChannelOverwrites(String channelId) =>
      _api.syncChannelOverwrites(channelId);

  Future<void> deleteChannelOverwrite({
    required String channelId,
    required OverwriteTarget kind,
    required String id,
  }) => _api.deleteChannelOverwrite(channelId: channelId, kind: kind, id: id);

  Future<List<ChannelOverwrite>> batchSetCategoryOverwrites({
    required String categoryId,
    required List<ChannelOverwriteEdit> overwrites,
  }) => _api.batchSetCategoryOverwrites(
    categoryId: categoryId,
    overwrites: overwrites,
  );

  Future<List<ChannelOverwrite>> batchSetChannelOverwrites({
    required String channelId,
    required List<ChannelOverwriteEdit> overwrites,
  }) => _api.batchSetChannelOverwrites(
    channelId: channelId,
    overwrites: overwrites,
  );

  Future<FetchedBytes> fetchSpaceBanner() => _api.fetchSpaceBanner();

  Future<FetchedBytes> fetchSpaceIcon() => _api.fetchSpaceIcon();
}

final settingsActionsProvider = Provider(
  (ref) => SettingsActions(ref.watch(apiProvider)),
);
