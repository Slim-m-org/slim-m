// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The names an audit row resolves its targets against: roles, channels,
/// categories and emoji as this client holds them now, plus what the loaded
/// log itself recorded for anything since deleted.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart' as data;

import '../../../providers/admin_providers.dart';
import '../../../providers/providers.dart';
import '../../members/providers/user_profiles.dart';
import 'admin_audit_wording.dart';
import 'admin_audit_log_controller.dart';

final _channelNamesProvider = StreamProvider.autoDispose<List<data.Channel>>((
  ref,
) {
  final store = ref.watch(storeProvider).valueOrNull;
  return store == null ? const Stream.empty() : store.watchChannels();
});

final _categoryNamesProvider =
    StreamProvider.autoDispose<List<data.ChannelCategoryRow>>((ref) {
      final store = ref.watch(storeProvider).valueOrNull;
      return store == null ? const Stream.empty() : store.watchCategories();
    });

final adminAuditNamesProvider = Provider.autoDispose<AuditNames>((ref) {
  final roles = ref.watch(rolesProvider).valueOrNull ?? const [];
  final emoji = ref.watch(customEmojiProvider).valueOrNull ?? const [];
  final channels = ref.watch(_channelNamesProvider).valueOrNull ?? const [];
  final categories = ref.watch(_categoryNamesProvider).valueOrNull ?? const [];
  final profiles = ref.watch(batchProfilesControllerProvider);
  final items = ref.watch(
    adminAuditLogControllerProvider.select((s) => s.items),
  );
  return AuditNames(
    roles: {for (final r in roles) r.id: r.name},
    channels: {for (final c in channels) c.id: c.name},
    categories: {for (final c in categories) c.id: c.name},
    emoji: {for (final e in emoji) e.id: e.name},
    users: {
      for (final p in profiles.entries)
        if (p.value != null) p.key: p.value!.displayName,
    },
    logged: AuditNames.loggedNames(items),
  );
});
