// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// The join gate and raid mode, as `/space/join-gate` reports them.
class JoinGate {
  const JoinGate({
    required this.enabled,
    required this.rules,
    required this.rulesChannelId,
    required this.joinsPaused,
  });

  /// New members wait until they accept [rules].
  final bool enabled;
  final String rules;

  /// The one channel a waiting member may read, or null for none.
  final String? rulesChannelId;

  /// Raid mode: nobody new may join, invite or not.
  final bool joinsPaused;

  factory JoinGate.fromJson(Map<String, dynamic> json) => JoinGate(
        enabled: json['enabled'] as bool? ?? false,
        rules: json['rules'] as String? ?? '',
        rulesChannelId: json['rules_channel_id'] as String?,
        joinsPaused: json['joins_paused'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'rules': rules,
        'rules_channel_id': rulesChannelId,
        'joins_paused': joinsPaused,
      };
}

/// The rules every member can read, and whether this account has accepted.
class SpaceRules {
  const SpaceRules({
    required this.rules,
    required this.rulesChannelId,
    required this.pending,
  });

  final String rules;
  final String? rulesChannelId;

  /// True until this account accepts the rules.
  final bool pending;

  factory SpaceRules.fromJson(Map<String, dynamic> json) => SpaceRules(
        rules: json['rules'] as String? ?? '',
        rulesChannelId: json['rules_channel_id'] as String?,
        pending: json['pending'] as bool? ?? false,
      );
}

extension SlimmApiJoinGate on SlimmApi {
  /// Requires MANAGE_SERVER.
  Future<JoinGate> joinGate() async {
    final json = await _send('GET', '/space/join-gate');
    return JoinGate.fromJson(json as Map<String, dynamic>);
  }

  /// Requires MANAGE_SERVER. Turning the gate off lets everyone waiting in.
  Future<JoinGate> setJoinGate(JoinGate gate) async {
    final json = await _send('PUT', '/space/join-gate', body: gate.toJson());
    return JoinGate.fromJson(json as Map<String, dynamic>);
  }

  Future<SpaceRules> spaceRules() async {
    final json = await _send('GET', '/space/rules');
    return SpaceRules.fromJson(json as Map<String, dynamic>);
  }

  Future<void> acceptSpaceRules() =>
      _send('POST', '/space/rules/accept', expectNoContent: true);
}
