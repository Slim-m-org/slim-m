// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile, member-moderation and report writes the member widgets make, so none of them talks to REST.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/providers.dart';

class MemberActions {
  const MemberActions(this._api);

  final SlimmApi _api;

  Future<UserProfile> updateMe({
    String? displayName,
    String? statusText,
    String? pronouns,
    String? about,
    int? profileColor,
    int? profileColorRgb,
  }) => _api.updateMe(
    displayName: displayName,
    statusText: statusText,
    pronouns: pronouns,
    about: about,
    profileColor: profileColor,
    profileColorRgb: profileColorRgb,
  );

  Future<UserProfile> uploadAvatar(List<int> bytes) => _api.uploadAvatar(bytes);

  Future<void> deleteAvatar() => _api.deleteAvatar();

  Future<UserProfile> uploadBanner(List<int> bytes) => _api.uploadBanner(bytes);

  Future<void> deleteBanner() => _api.deleteBanner();

  Future<void> clearMemberTotp(String userId, {required String password}) =>
      _api.clearMemberTotp(userId, password: password);

  Future<Invite> createInvite({
    int? maxUses,
    int? expiresAt,
    String? roleGrant,
    bool reuse = false,
  }) => _api.createInvite(
    maxUses: maxUses,
    expiresAt: expiresAt,
    roleGrant: roleGrant,
    reuse: reuse,
  );

  Future<int> uploadSpaceBanner(List<int> bytes) =>
      _api.uploadSpaceBanner(bytes);

  Future<int> uploadSpaceIcon(List<int> bytes) => _api.uploadSpaceIcon(bytes);

  Future<void> deleteSpaceIcon() => _api.deleteSpaceIcon();

  Future<void> deleteSpaceBanner() => _api.deleteSpaceBanner();

  Future<void> removeMember({required String userId, String? reason}) =>
      _api.removeMember(userId: userId, reason: reason);

  Future<void> bulkRemoveMembers({
    required List<String> userIds,
    String? reason,
  }) => _api.bulkRemoveMembers(userIds: userIds, reason: reason);

  Future<void> bulkTimeoutMembers({
    required List<String> userIds,
    required Duration duration,
    String? reason,
  }) => _api.bulkTimeoutMembers(
    userIds: userIds,
    duration: duration,
    reason: reason,
  );

  Future<int> timeOutMember({
    required String userId,
    required Duration duration,
    String? reason,
  }) => _api.timeOutMember(userId: userId, duration: duration, reason: reason);

  Future<void> liftMemberTimeout(String userId) =>
      _api.liftMemberTimeout(userId);

  Future<void> kickVoiceParticipant(String channelId, String userId) =>
      _api.kickVoiceParticipant(channelId, userId);

  Future<UserNote> setUserNote(String userId, String body) =>
      _api.setUserNote(userId, body);

  Future<void> setMemberNickname({
    required String userId,
    required String nickname,
  }) => _api.setMemberNickname(userId: userId, nickname: nickname);

  Future<void> clearMemberNickname(String userId) =>
      _api.clearMemberNickname(userId);

  Future<PresenceVisibility> setPresenceVisibility(
    PresenceVisibility visibility,
  ) => _api.setPresenceVisibility(visibility);

  Future<MyReportStatus> myReportStatus(String reportId) =>
      _api.myReportStatus(reportId);

  Future<ResetCodeIssued> issueResetCode(
    String userId, {
    required String password,
  }) => _api.issueResetCode(userId, password: password);

  Future<String> report({
    required ReportSubject subject,
    required String subjectId,
    required String reason,
    String? id,
    String? channelId,
    String? authorId,
    String? snapshot,
  }) => _api.report(
    subject: subject,
    subjectId: subjectId,
    reason: reason,
    id: id,
    channelId: channelId,
    authorId: authorId,
    snapshot: snapshot,
  );

  Future<void> assignRole({required String userId, required String roleId}) =>
      _api.assignRole(userId: userId, roleId: roleId);

  Future<void> unassignRole({required String userId, required String roleId}) =>
      _api.unassignRole(userId: userId, roleId: roleId);
}

final memberActionsProvider = Provider(
  (ref) => MemberActions(ref.watch(apiProvider)),
);
