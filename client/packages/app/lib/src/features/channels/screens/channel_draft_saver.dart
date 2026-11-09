// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps a channel's unsent composer text on disk while it is being typed, so
/// an app kill or a quit loses at most the last pause's worth of words rather
/// than everything since the channel was opened.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../providers/channel_drafts.dart';

/// How long the field must sit still before its text is written.
const channelDraftSaveDelay = Duration(milliseconds: 500);

/// Saves [composer]'s text as the draft of whichever channel [channelId] names
/// when typing pauses, and at once when the app leaves the foreground.
class ChannelDraftSaver with WidgetsBindingObserver {
  ChannelDraftSaver({
    required this.composer,
    required this.drafts,
    required this.channelId,
  }) {
    composer.addListener(_onChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  final TextEditingController composer;
  final ChannelDraftsController drafts;

  /// A callback because one `ChannelScreen` State outlives a channel switch.
  final String Function() channelId;
  Timer? _pause;

  void _onChanged() {
    _pause?.cancel();
    _pause = Timer(channelDraftSaveDelay, flush);
  }

  /// Writes the text now, unless it already is the saved draft.
  void flush() {
    _pause?.cancel();
    final id = channelId();
    if (composer.text != drafts.draftFor(id)) drafts.save(id, composer.text);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) flush();
  }

  void dispose() {
    _pause?.cancel();
    composer.removeListener(_onChanged);
    WidgetsBinding.instance.removeObserver(this);
  }
}
