// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel and category writes the channel widgets make, each paired with
/// the local store write the rail reads back, so no widget talks to REST.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_data/data.dart' hide Channel;

import '../../../providers/providers.dart';
import 'category_nesting.dart';

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
    bool createsRooms = false,
    NotificationPreference defaultNotification =
        NotificationPreference.everything,
    String? id,
  }) async {
    var created = await _api.createChannel(
      name: name,
      kind: kind,
      categoryId: categoryId,
      restricted: restricted,
      joinMuted: joinMuted,
      createsRooms: createsRooms,
      defaultNotification: defaultNotification,
      id: id,
    );
    // A server older than lobby-on-create ignores the field; the settings route has always taken it.
    if (createsRooms && !created.createsRooms) {
      created = await _api.updateChannel(
        created.id,
        const ChannelUpdate(createsRooms: true),
      );
    }
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

  /// [parentId] files it under that top-level category (decision 0120).
  Future<void> createCategory(
    String name, {
    String? id,
    String? parentId,
  }) async {
    final created = await _api.createCategory(name, id: id, parentId: parentId);
    if (created.serverNests) {
      _ref.read(categoriesNestProvider.notifier).state = true;
    }
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
