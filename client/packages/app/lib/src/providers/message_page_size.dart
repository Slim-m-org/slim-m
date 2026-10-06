// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How many older messages one backwards page of a channel's history asks for.
///
/// The performance lever for scrolling back: a smaller page is a lighter,
/// snappier request that holds less in memory at once, a larger page means
/// fewer round trips reading a long history at the cost of a heavier fetch.
/// Every choice stays at or under the server's `MAX_LIMIT` of 100, which is
/// load-bearing - `ChannelHistoryController` reads a page shorter than it asked
/// for as the end of history, so a request the server clamped would read as a
/// false "start of channel". The default matches what this app has always
/// fetched, so leaving it alone changes nothing.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'preference_controller.dart';

/// A backwards-page size, each a concrete row count at or under the server cap.
enum MessagePageSize { small, standard, large }

extension MessagePageSizeX on MessagePageSize {
  /// The row count this asks the server for, always `<= 100`.
  int get rows => switch (this) {
    MessagePageSize.small => 25,
    MessagePageSize.standard => 50,
    MessagePageSize.large => 100,
  };

  String get label => switch (this) {
    MessagePageSize.small => 'Smaller (25)',
    MessagePageSize.standard => 'Standard (50, default)',
    MessagePageSize.large => 'Larger (100)',
  };
}

const messagePageSizeKey = 'slimm.performance.message_page_size';

const defaultMessagePageSize = MessagePageSize.standard;

class MessagePageSizeController
    extends EnumPreferenceController<MessagePageSize> {
  MessagePageSizeController(
    super.ref, [
    MessagePageSize initial = defaultMessagePageSize,
  ]) : super(
         storageKey: messagePageSizeKey,
         choices: MessagePageSize.values,
         fallback: initial,
       );
}

final messagePageSizeControllerProvider =
    StateNotifierProvider<MessagePageSizeController, MessagePageSize>(
      MessagePageSizeController.new,
    );
