// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Deployment-wide space settings models.
library;

import 'models_totp.dart';

/// Who may create an account on this deployment.
enum JoinPolicy {
  /// A valid invite code is required. The default, and what every deployment
  /// keeps unless somebody changes it.
  invite,

  /// Anyone who can reach the server may register. A code is still accepted,
  /// so an invite granting a role keeps working.
  open;

  String get wire => name;

  /// An unrecognised policy reads as [invite]. A server that grows a third
  /// value must not read as open to a client that has never heard of it.
  static JoinPolicy parse(String value) =>
      value == 'open' ? JoinPolicy.open : JoinPolicy.invite;
}

/// Deployment-wide settings, as `/space/settings` reports them.
///
/// Declared here rather than in `models_totp.dart` because [JoinPolicy] is
/// declared here, and that file is a separate library which cannot see it.
class SpaceSettings {
  const SpaceSettings({
    this.name = 'slim-m',
    required this.joinPolicy,
    required this.totpPolicy,
    this.description = '',
    this.bannerUpdatedAt,
    this.iconUpdatedAt,
    this.strongNoiseSuppression = false,
    this.membersCanInvite = false,
    this.welcomeEnabled = false,
    this.welcomeChannelId,
    this.welcomeMessage = '',
  });

  /// The Space's name, shown in the channel list header and on invites.
  final String name;

  final JoinPolicy joinPolicy;
  final TotpPolicy totpPolicy;

  /// Shown on the invite landing card; empty when none is set.
  final String description;

  /// When the banner was set, or null for none.
  final int? bannerUpdatedAt;

  /// When the icon was set, or null for none.
  final int? iconUpdatedAt;

  /// What "Space default" means for members' noise suppression.
  final bool strongNoiseSuppression;

  /// Whether every member may create invites, not only holders of CREATE_INVITE.
  final bool membersCanInvite;

  /// Whether a welcome message is posted when someone joins.
  final bool welcomeEnabled;

  /// The text channel the welcome is posted in, or null for none.
  final String? welcomeChannelId;

  /// The welcome template, with `{user}` and `{space}` placeholders.
  final String welcomeMessage;

  /// `totp_policy` is absent from a server older than decision 0048, which
  /// reads as [TotpPolicy.optional] rather than failing the whole settings load
  /// over a field the rest of the screen does not need.
  factory SpaceSettings.fromJson(Map<String, dynamic> json) => SpaceSettings(
        name: json['name'] as String? ?? 'slim-m',
        joinPolicy: JoinPolicy.parse(json['join_policy'] as String),
        totpPolicy: TotpPolicy.parse(
          json['totp_policy'] as String? ?? TotpPolicy.optional.wire,
        ),
        description: json['description'] as String? ?? '',
        bannerUpdatedAt: json['banner_updated_at'] as int?,
        iconUpdatedAt: json['icon_updated_at'] as int?,
        strongNoiseSuppression:
            json['strong_noise_suppression'] as bool? ?? false,
        membersCanInvite: json['members_can_invite'] as bool? ?? false,
        welcomeEnabled: json['welcome_enabled'] as bool? ?? false,
        welcomeChannelId: json['welcome_channel_id'] as String?,
        welcomeMessage: json['welcome_message'] as String? ?? '',
      );
}

/// The space settings one [SlimmApiSpace.setSpaceSettings] call writes; a null
/// field is omitted. An empty [welcomeChannelId] clears the welcome channel.
class SpaceSettingsUpdate {
  const SpaceSettingsUpdate({
    this.name,
    this.joinPolicy,
    this.totpPolicy,
    this.description,
    this.strongNoiseSuppression,
    this.membersCanInvite,
    this.welcomeEnabled,
    this.welcomeChannelId,
    this.welcomeMessage,
  });

  final String? name;
  final JoinPolicy? joinPolicy;
  final TotpPolicy? totpPolicy;
  final String? description;
  final bool? strongNoiseSuppression;
  final bool? membersCanInvite;
  final bool? welcomeEnabled;
  final String? welcomeChannelId;
  final String? welcomeMessage;
}
