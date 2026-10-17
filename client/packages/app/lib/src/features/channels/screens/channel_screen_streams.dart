// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two per-channel drift streams `ChannelScreen` watches, cached so a
/// rebuild that leaves the channel id and window unchanged reuses the same
/// `Stream` instance instead of asking drift to start a fresh query.
///
/// A fresh `Stream` from `MessageStore.watchChannelRow`/`watchChannel` is a
/// fresh query underneath, so building `StreamBuilder(stream: store.watch...)`
/// inline in `build` made every rebuild (a reaction, a hover, a keystroke)
/// resubscribe and re-run it. Split out of `channel_screen.dart` to keep that
/// file under the repo's line budget.
library;

import 'package:slimm_data/data.dart';

class ChannelStreamCache {
  MessageStore? _rowStore;
  String? _rowChannelId;
  Stream<Channel?>? _rowStream;

  MessageStore? _transcriptStore;
  String? _transcriptChannelId;
  int? _transcriptWindow;
  Stream<List<Message>>? _transcriptStream;

  /// [store.watchChannelRow], recreated only when [store] or [channelId]
  /// changes rather than on every call.
  Stream<Channel?> channelRow(MessageStore store, String channelId) {
    if (_rowStore != store || _rowChannelId != channelId) {
      _rowStore = store;
      _rowChannelId = channelId;
      _rowStream = store.watchChannelRow(channelId);
    }
    return _rowStream!;
  }

  /// [store.watchChannel], recreated only when [store], [channelId] or
  /// [window] changes rather than on every call.
  Stream<List<Message>> transcript(
    MessageStore store,
    String channelId,
    int window,
  ) {
    if (_transcriptStore != store ||
        _transcriptChannelId != channelId ||
        _transcriptWindow != window) {
      _transcriptStore = store;
      _transcriptChannelId = channelId;
      _transcriptWindow = window;
      _transcriptStream = store.watchChannel(channelId, limit: window);
    }
    return _transcriptStream!;
  }
}
