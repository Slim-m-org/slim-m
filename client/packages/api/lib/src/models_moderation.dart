// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Report triage and invite management.
///
/// Split out of models.dart purely to stay under this repo's line budget; see
/// that file for how the pieces are recombined into one import.
library;

import 'models.dart';

/// What a report is about.
enum ReportSubject {
  message,
  user,

  /// A bot's private message. The server kept no copy, so a report carries the
  /// text the reporter was shown.
  ephemeralMessage;

  String get wire => switch (this) {
        ephemeralMessage => 'ephemeral_message',
        _ => name,
      };

  /// An unrecognised value reads as [user]: it is the more generic subject,
  /// so a future kind this client has never heard of does not get rendered
  /// as reported message content - an author and a snapshot - that may not
  /// exist for whatever that new kind turns out to be.
  static ReportSubject parse(String value) => switch (value) {
        'message' => ReportSubject.message,
        'ephemeral_message' => ReportSubject.ephemeralMessage,
        _ => ReportSubject.user,
      };
}

/// A moderation report awaiting triage.
class Report {
  const Report({
    required this.id,
    required this.reporterId,
    required this.subjectKind,
    required this.subjectId,
    required this.channelId,
    required this.reason,
    required this.snapshot,
    required this.subjectAuthorId,
    required this.createdAt,
    this.channelPermissions,
  });

  final String id;

  /// Null once the reporter's account has been anonymized.
  final String? reporterId;
  final ReportSubject subjectKind;
  final String subjectId;

  /// Null for a user report, which has no channel of its own.
  final String? channelId;
  final String reason;

  /// The reported content as it stood at filing time. Absent for a user
  /// report; the author may have since edited or deleted it.
  final String? snapshot;

  /// Who wrote the reported message. Null for a user report (there is no
  /// message), for a message since hard-deleted, and once the author's account
  /// has been anonymized - the same three cases `authorId` is null on a
  /// [Message].
  final String? subjectAuthorId;

  /// Unix milliseconds.
  final int createdAt;

  /// The caller's effective bitmask in [channelId], null exactly when
  /// [channelId] is null. Batched per page, masked to zero whenever the
  /// caller lacks VIEW_CHANNEL - the same rule
  /// [SlimmApiChannelAdmin.getChannelPermissions] applies. A DM report's
  /// bitmask structurally never carries `manageMessages`, since no one holds
  /// that permission in a DM. Absent on a server too old to send it, which a
  /// caller must treat as unknown rather than as zero permissions.
  final int? channelPermissions;

  factory Report.fromJson(Map<String, dynamic> json) => Report(
        id: json['id'] as String,
        reporterId: json['reporter_id'] as String?,
        subjectKind: ReportSubject.parse(json['subject_kind'] as String),
        subjectId: json['subject_id'] as String,
        channelId: json['channel_id'] as String?,
        reason: json['reason'] as String,
        snapshot: json['snapshot'] as String?,
        subjectAuthorId: json['subject_author_id'] as String?,
        createdAt: json['created_at'] as int,
        channelPermissions: json['channel_permissions'] as int?,
      );
}

/// How a report was closed.
enum ReportResolution {
  resolved,
  dismissed;

  String get wire => name;
}

/// A reporter's own, narrow view of a report they filed - what
/// [SlimmApiModeration.myReportStatus] returns.
///
/// Deliberately smaller than [Report]: no `reporterId` (it is always the
/// caller), no `snapshot`, no `subjectAuthorId`, and no moderator identity or
/// resolution detail. See that method's own doc for why.
class MyReportStatus {
  const MyReportStatus({
    required this.id,
    required this.subjectKind,
    required this.subjectId,
    required this.channelId,
    required this.createdAt,
    required this.resolved,
  });

  final String id;
  final ReportSubject subjectKind;
  final String subjectId;

  /// Null for a user report, which has no channel of its own.
  final String? channelId;

  /// Unix milliseconds; when the reporter filed it.
  final int createdAt;

  /// Whether a moderator has closed it. Never which one, or what they
  /// decided - see [MyReportStatus]'s own doc.
  final bool resolved;

  factory MyReportStatus.fromJson(Map<String, dynamic> json) => MyReportStatus(
        id: json['id'] as String,
        subjectKind: ReportSubject.parse(json['subject_kind'] as String),
        subjectId: json['subject_id'] as String,
        channelId: json['channel_id'] as String?,
        createdAt: json['created_at'] as int,
        resolved: (json['status'] as String) == 'resolved',
      );
}

/// An invite code.
class Invite {
  const Invite({
    required this.code,
    required this.maxUses,
    required this.uses,
    required this.expiresAt,
    required this.createdAt,
    required this.revoked,
    required this.usable,
    this.roleGrant,
  });

  final String code;

  /// Null means unlimited.
  final int? maxUses;
  final int uses;

  /// Unix milliseconds; null means it never expires.
  final int? expiresAt;

  /// Unix milliseconds.
  final int createdAt;
  final bool revoked;

  /// Whether the invite can be redeemed right now.
  final bool usable;

  /// A role every account redeeming this code receives, or null for none.
  final String? roleGrant;

  factory Invite.fromJson(Map<String, dynamic> json) => Invite(
        code: json['code'] as String,
        maxUses: json['max_uses'] as int?,
        uses: json['uses'] as int,
        expiresAt: json['expires_at'] as int?,
        createdAt: json['created_at'] as int,
        revoked: json['revoked'] as bool,
        usable: json['usable'] as bool,
        roleGrant: json['role_grant'] as String?,
      );
}

/// Whether an invite code can be redeemed right now, and if so, a preview of
/// what it joins.
///
/// A sealed type rather than nullable fields on one flat class, so
/// [InviteUsable.community] is only reachable once a caller has matched that
/// branch: it cannot be read (or accidentally rendered half-populated)
/// without first learning the code actually works. The unusable branch
/// carries no fields at all, mirroring the wire body being exactly
/// `{"usable": false}` whether the code is expired, spent, revoked, or was
/// never issued, so a caller cannot mine codes by branching on why.
sealed class InviteCheck {
  const InviteCheck();

  factory InviteCheck.fromJson(Map<String, dynamic> json) {
    if (json['usable'] != true) return const InviteUnusable();
    return InviteUsable(
      InviteCommunity.fromJson(json['community'] as Map<String, dynamic>),
    );
  }
}

/// The code works right now, and previews the deployment it joins.
class InviteUsable extends InviteCheck {
  const InviteUsable(this.community);

  final InviteCommunity community;
}

/// The code cannot be redeemed. Deliberately carries no reason: expired,
/// spent, revoked, and never-issued are indistinguishable over the wire.
class InviteUnusable extends InviteCheck {
  const InviteUnusable();
}

/// The community metadata an invite discloses, once it is known to be
/// usable. Reaching this already proves the caller holds a working code, so
/// none of this is more than they had already demonstrated.
class InviteCommunity {
  const InviteCommunity({
    required this.name,
    required this.memberCount,
    required this.invitedBy,
    required this.usesRemaining,
    required this.expiresAt,
    this.description = '',
    this.bannerUpdatedAt,
    this.iconUpdatedAt,
  });

  /// This deployment's display name.
  final String name;

  /// How many live accounts the deployment has.
  final int memberCount;

  /// The inviter's current display name, or null if their account has since
  /// been deleted.
  final String? invitedBy;

  /// Null means unlimited.
  final int? usesRemaining;

  /// Unix milliseconds; null means it never expires.
  final int? expiresAt;

  /// The admin's short blurb; empty when none is set.
  final String description;

  /// When the banner was set, or null for none. A server that predates the
  /// landing card sends neither field.
  final int? bannerUpdatedAt;

  /// When the icon was set, or null for none.
  final int? iconUpdatedAt;

  factory InviteCommunity.fromJson(Map<String, dynamic> json) =>
      InviteCommunity(
        name: json['name'] as String,
        memberCount: json['member_count'] as int,
        invitedBy: json['invited_by'] as String?,
        usesRemaining: json['uses_remaining'] as int?,
        expiresAt: json['expires_at'] as int?,
        description: json['description'] as String? ?? '',
        bannerUpdatedAt: json['banner_updated_at'] as int?,
        iconUpdatedAt: json['icon_updated_at'] as int?,
      );
}

/// A member removed from the Space, as the administration screen that
/// reverses it sees them.
///
/// Carries their name because `GET /members` deliberately no longer does:
/// this listing is the only place a removed member is still nameable.
class SpaceRemoval {
  const SpaceRemoval({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.removedAt,
    this.reason,
    this.removedBy,
  });

  final String userId;
  final String username;
  final String displayName;

  /// Unix milliseconds.
  final int removedAt;

  final String? reason;

  /// Null once the removing moderator's own account is deleted.
  final String? removedBy;

  factory SpaceRemoval.fromJson(Map<String, dynamic> json) => SpaceRemoval(
        userId: json['user_id'] as String,
        username: json['username'] as String,
        displayName: json['display_name'] as String,
        removedAt: json['removed_at'] as int,
        reason: json['reason'] as String?,
        removedBy: json['removed_by'] as String?,
      );
}
