// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Profiles: a public [UserProfile] and the caller's own richer [Me].
///
/// Split out of models.dart purely to stay under this repo's line budget; see
/// that file for how the pieces are recombined into one import.
library;

/// A user's public profile, visible to anyone signed in to the same
/// deployment: the shape returned for another member, never the caller's own
/// richer view.
class UserProfile {
  const UserProfile({
    required this.id,
    required this.username,
    required this.displayName,
    required this.createdAt,
    this.nickname,
    this.accountDisplayName,
    this.avatarUpdatedAt,
    this.bannerUpdatedAt,
    this.roles = const [],
    this.roleIds = const [],
    this.hoistedRoleId,
    this.hoistedRolePosition,
    this.timedOutUntil,
    this.statusText,
    this.pronouns,
    this.about,
    this.profileColor,
    this.profileColorRgb,
    this.isBot = false,
    this.isWebhook = false,
    this.inviteCode,
  });

  final String id;
  final String username;

  /// What readers see: [nickname] when an administrator gave this account
  /// one, else the account's own name ([accountDisplayName]).
  final String displayName;

  /// The space-local name an administrator gave this account, or null. See
  /// `docs/decisions/0055-member-nicknames.md`.
  final String? nickname;

  /// The account's own name, whatever [nickname] is. Null on a server older
  /// than nicknames, where [displayName] already is the account's own.
  final String? accountDisplayName;

  /// Unix milliseconds.
  final int createdAt;

  /// When this user's avatar was last set, or null for no avatar. Not itself
  /// fetchable: pass it as a client-side cache key alongside
  /// [SlimmApi.fetchAvatar], since the fetch endpoint itself ignores any
  /// query string. Null means no avatar, so a caller must not request one.
  final int? avatarUpdatedAt;

  /// When this user's profile banner image was set, or null for the profile
  /// colour. A cache key beside [SlimmApi.fetchBanner]; null means do not ask.
  final int? bannerUpdatedAt;

  /// Role names, for a badge beside the member. Excludes `@everyone`, which
  /// every member holds, so an empty list means "no badge" rather than "no
  /// data".
  final List<String> roles;

  /// The same roles as ids, positionally matching [roles].
  ///
  /// Deciding "does this member hold that role" needs these, not the names:
  /// nothing stops two roles sharing a name, and matching by name lights up
  /// both. Empty on a server older than the field, which is why the roles
  /// sheet treats an id it cannot resolve as unknown rather than as unheld.
  final List<String> roleIds;

  /// The hoisted role the member pane lists this member under, or null when
  /// none of theirs is hoisted (or the server predates the field). One of
  /// [roleIds] when set.
  final String? hoistedRoleId;

  /// [hoistedRoleId]'s hierarchy position, higher first, so sections order
  /// exactly without `GET /roles`, which needs MANAGE_ROLES.
  final int? hoistedRolePosition;

  /// When this member's timeout lifts, in Unix milliseconds, or null if they
  /// are not timed out. Already resolved against the clock server-side, so an
  /// elapsed timeout arrives as null rather than as a past deadline.
  final int? timedOutUntil;

  /// A short free-text status line this member set for themselves, or null
  /// for none - shown in the member pane under the name. Absent (not just
  /// null) on a server older than this field, which a caller must treat as
  /// unknown rather than as "no status".
  final String? statusText;

  /// A short self-described pronoun set ("she/her"), or null if unset. Shown
  /// on the member card beside the `@handle`. Absent (not just null) on a
  /// server older than this field.
  final String? pronouns;

  /// A short "about" line (190 characters), or null if unset. Shown on the
  /// member card under the status line. Absent on a server older than this
  /// field.
  final String? about;

  /// An index into the design system's closed categorical colour set
  /// (`AppCanvasColors.cursors`), or null on a server older than this field -
  /// a caller falls back to a locally computed default in that case, the same
  /// one the server computes for an account that has not chosen one yet.
  final int? profileColor;

  /// A custom colour as 0xRRGGBB that wins over [profileColor], or null for
  /// the preset (and on a server older than this field).
  final int? profileColorRgb;

  /// Whether this account is a bot rather than a person, which the interface
  /// draws a badge from. False on a server older than this field: an older
  /// deployment has no bots to mistake anyone for, so reading absent as "not a
  /// bot" is accurate there rather than merely safe.
  ///
  /// Says nothing about what the account may do - that is its roles, exactly
  /// as for a person. See `docs/decisions/0028-bot-accounts.md`.
  final bool isBot;

  /// Whether this account is a webhook's principal rather than a person or a
  /// bot, which the interface draws its always-on `Webhook` badge from. False
  /// on a server older than this field: an older deployment has no webhooks
  /// to mistake anyone for, so reading absent as "not a webhook" is accurate
  /// there rather than merely safe. A webhook never appears in the member
  /// list, so this is only ever seen by resolving a message's own author id.
  /// See `docs/decisions/0030-incoming-webhooks.md`.
  final bool isWebhook;

  /// The invite this member registered through, sent only to a caller who
  /// can manage roles, as a sign of a returning account.
  final String? inviteCode;

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        id: json['id'] as String,
        username: json['username'] as String,
        displayName: json['display_name'] as String,
        nickname: json['nickname'] as String?,
        accountDisplayName: json['account_display_name'] as String?,
        createdAt: json['created_at'] as int,
        avatarUpdatedAt: json['avatar_updated_at'] as int?,
        bannerUpdatedAt: json['banner_updated_at'] as int?,
        // Absent on a server older than the roles field is not the same as a
        // member holding none, but both render no badge, so empty reads either.
        roles: (json['roles'] as List<dynamic>?)?.cast<String>() ?? const [],
        roleIds:
            (json['role_ids'] as List<dynamic>?)?.cast<String>() ?? const [],
        hoistedRoleId: json['hoisted_role_id'] as String?,
        hoistedRolePosition: json['hoisted_role_position'] as int?,
        timedOutUntil: json['timed_out_until'] as int?,
        statusText: json['status_text'] as String?,
        pronouns: json['pronouns'] as String?,
        about: json['about'] as String?,
        profileColor: json['profile_color'] as int?,
        profileColorRgb: json['profile_color_rgb'] as int?,
        isBot: json['is_bot'] as bool? ?? false,
        isWebhook: json['is_webhook'] as bool? ?? false,
        inviteCode: json['invite_code'] as String?,
      );

  /// Value equality so a `.select`ed [UserProfile] (see
  /// `providers/user_profiles.dart`'s `AuthorResolution`) compares by field,
  /// not by the fresh instance a re-resolve constructs even when the server
  /// sent back the exact same fields.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UserProfile &&
          id == other.id &&
          username == other.username &&
          displayName == other.displayName &&
          nickname == other.nickname &&
          createdAt == other.createdAt &&
          avatarUpdatedAt == other.avatarUpdatedAt &&
          bannerUpdatedAt == other.bannerUpdatedAt &&
          hoistedRoleId == other.hoistedRoleId &&
          hoistedRolePosition == other.hoistedRolePosition &&
          timedOutUntil == other.timedOutUntil &&
          statusText == other.statusText &&
          pronouns == other.pronouns &&
          about == other.about &&
          profileColor == other.profileColor &&
          profileColorRgb == other.profileColorRgb &&
          inviteCode == other.inviteCode &&
          _listEquals(roles, other.roles) &&
          _listEquals(roleIds, other.roleIds));

  @override
  int get hashCode => Object.hash(
        id,
        username,
        displayName,
        nickname,
        createdAt,
        avatarUpdatedAt,
        bannerUpdatedAt,
        hoistedRoleId,
        hoistedRolePosition,
        timedOutUntil,
        statusText,
        pronouns,
        about,
        profileColor,
        profileColorRgb,
        inviteCode,
        Object.hashAll(roles),
        Object.hashAll(roleIds),
      );
}

/// Element-wise list equality, since `List` itself only compares by
/// reference; kept minimal here rather than pulling in `package:collection`
/// for one call site.
bool _listEquals(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The caller's own profile plus their effective base (deployment-level)
/// permissions.
///
/// Base permissions ignore any per-channel overwrite. They are a UI nicety
/// for deciding what to show; every write is still re-authorized server-side
/// from scratch regardless of what this says.
class Me {
  const Me({
    required this.id,
    required this.username,
    required this.displayName,
    required this.createdAt,
    required this.permissions,
    this.avatarUpdatedAt,
    this.bannerUpdatedAt,
    this.timedOutUntil,
    this.timeoutReason,
    this.statusText,
    this.pronouns,
    this.about,
    this.profileColor,
    this.profileColorRgb,
    this.presenceVisibility,
  });

  final String id;
  final String username;
  final String displayName;

  /// Unix milliseconds.
  final int createdAt;

  /// The raw permission bitmask; see the server's `Permissions` type for what
  /// each bit means.
  final int permissions;

  /// Same meaning as [UserProfile.avatarUpdatedAt].
  final int? avatarUpdatedAt;

  /// Same meaning as [UserProfile.bannerUpdatedAt].
  final int? bannerUpdatedAt;

  /// When the caller's own timeout lifts, or null.
  ///
  /// [permissions] already has the timeout subtracted, so a UI hiding actions
  /// on a missing bit needs no separate rule; this is what lets it say why
  /// rather than leaving somebody with a dead composer and no explanation.
  final int? timedOutUntil;

  /// Why the caller was timed out, or null if they are not timed out, or the
  /// moderator left no reason. Self-view only: the server never puts this on
  /// [UserProfile], which other members can read.
  final String? timeoutReason;

  /// The caller's own status line; same meaning as [UserProfile.statusText].
  final String? statusText;

  /// Same meaning as [UserProfile.pronouns].
  final String? pronouns;

  /// Same meaning as [UserProfile.about].
  final String? about;

  /// Same meaning as [UserProfile.profileColor].
  final int? profileColor;

  /// Same meaning as [UserProfile.profileColorRgb].
  final int? profileColorRgb;

  /// The caller's own stored presence choice: online, away, dnd or hidden.
  /// Null from a server that predates the field. Self-view only.
  final String? presenceVisibility;

  factory Me.fromJson(Map<String, dynamic> json) => Me(
        id: json['id'] as String,
        username: json['username'] as String,
        displayName: json['display_name'] as String,
        createdAt: json['created_at'] as int,
        permissions: json['permissions'] as int,
        avatarUpdatedAt: json['avatar_updated_at'] as int?,
        bannerUpdatedAt: json['banner_updated_at'] as int?,
        timedOutUntil: json['timed_out_until'] as int?,
        timeoutReason: json['timeout_reason'] as String?,
        statusText: json['status_text'] as String?,
        pronouns: json['pronouns'] as String?,
        about: json['about'] as String?,
        profileColor: json['profile_color'] as int?,
        profileColorRgb: json['profile_color_rgb'] as int?,
        presenceVisibility: json['presence_visibility'] as String?,
      );
}
