// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel and category writes the channel widgets make, each paired with
/// the local store write the rail reads back, so no widget talks to REST.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_data/data.dart' hide Channel;

import '../../../providers/providers.dart';

class ChannelActions {
  ChannelActions(this._ref);

  final Ref _ref;

  SlimmApi get _api => _ref.read(apiProvider);

  Future<Channel> createChannel({
    required String name,
    required String kind,
    String? categoryId,
    bool restricted = false,
    bool joinMuted = false,
    NotificationPreference defaultNotification =
        NotificationPreference.everything,
    String? id,
  }) async {
    final created = await _api.createChannel(
      name: name,
      kind: kind,
      categoryId: categoryId,
      restricted: restricted,
      joinMuted: joinMuted,
      defaultNotification: defaultNotification,
      id: id,
    );
    final store = await _ref.read(storeProvider.future);
    await store.upsertChannels([created]);
    return created;
  }

  Future<void> setOverwrites(
    String channelId,
    List<ChannelOverwriteEdit> edits,
  ) => _api.batchSetChannelOverwrites(channelId: channelId, overwrites: edits);

  Future<Channel> update(String channelId, ChannelUpdate update) async {
    final updated = await _api.updateChannel(channelId, update);
    final store = await _ref.read(storeProvider.future);
    await store.upsertChannels([updated]);
    return updated;
  }

  Future<void> delete(String channelId) async {
    await _api.deleteChannel(channelId);
    final store = await _ref.read(storeProvider.future);
    await store.removeChannel(channelId);
  }

  Future<void> createCategory(String name, {String? id}) async {
    final created = await _api.createCategory(name, id: id);
    final store = await _ref.read(storeProvider.future);
    await store.upsertCategory(created);
  }

  Future<void> renameCategory(String categoryId, String name) async {
    final updated = await _api.updateCategory(
      categoryId: categoryId,
      name: name,
    );
    final store = await _ref.read(storeProvider.future);
    await store.upsertCategory(updated);
  }

  Future<void> deleteCategory(ChannelCategoryRow category) async {
    await _api.deleteCategory(category.id);
    final store = await _ref.read(storeProvider.future);
    await store.removeCategory(category.id);
  }

  Future<ChannelRetention> retention(String channelId) =>
      _api.channelRetention(channelId);

  Future<int?> previewRetention(String channelId, int days) =>
      _api.previewChannelRetention(channelId, days);

  Future<void> setRetention(String channelId, int? days) =>
      _api.setChannelRetention(channelId, days);
}

final channelActionsProvider = Provider<ChannelActions>(ChannelActions.new);
