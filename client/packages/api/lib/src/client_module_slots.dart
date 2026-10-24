// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

const int _maxBadgeIds = 100;

/// What installed modules show for members, per decision 0091's slot routes.
extension SlimmApiModuleSlots on SlimmApi {
  /// The profile sections modules contribute for [userId]; a module that
  /// failed is simply absent.
  Future<List<ModuleProfileSection>> moduleProfileSlots(String userId) async {
    final json = await _send('GET', '/space/dock/slots/profile/$userId');
    final raw = json is Map ? json['sections'] : null;
    if (raw is! List) return const [];
    return raw
        .map(ModuleProfileSection.tryParse)
        .whereType<ModuleProfileSection>()
        .toList(growable: false);
  }

  /// The badges modules show beside each of [userIds], keyed by member id. A
  /// member with none is absent. Asks in batches of 100, the server's cap.
  Future<Map<String, List<ModuleBadge>>> moduleBadges(
    List<String> userIds,
  ) async {
    final ids = userIds.toSet().toList(growable: false);
    final out = <String, List<ModuleBadge>>{};
    for (var i = 0; i < ids.length; i += _maxBadgeIds) {
      final end = i + _maxBadgeIds < ids.length ? i + _maxBadgeIds : ids.length;
      final json = await _send(
        'GET',
        '/space/dock/slots/badges',
        query: {'ids': ids.sublist(i, end).join(',')},
      );
      _collectBadges(json, out);
    }
    return out;
  }

  /// Adds the badges in one `badges` answer to [out], skipping anything malformed.
  static void _collectBadges(Object? json, Map<String, List<ModuleBadge>> out) {
    final badges = json is Map ? json['badges'] : null;
    if (badges is! Map) return;
    for (final entry in badges.entries) {
      final list = entry.value;
      if (entry.key is! String || list is! List) continue;
      final parsed = list
          .map(ModuleBadge.tryParse)
          .whereType<ModuleBadge>()
          .toList(growable: false);
      if (parsed.isNotEmpty) out[entry.key as String] = parsed;
    }
  }
}
