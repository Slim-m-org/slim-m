// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The palette's transcript hits for the current text. A newer query retires
/// one still in flight, and the search waits out the same pause as the
/// message search, so one pause sends both.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:slimm_api/api.dart' as api;

import '../../messages/providers/message_search.dart';
import '../../voice/providers/transcript_search.dart';

class PaletteTranscriptSearch extends ChangeNotifier {
  PaletteTranscriptSearch(
    this._read, {
    required this.limit,
    required this.pause,
  });

  final ProviderReader _read;
  final int limit;
  final Duration pause;
  List<api.TranscriptHit> results = const [];
  int _generation = 0;
  Timer? _timer;
  bool _disposed = false;

  /// Drops the hits and any search still pending.
  void clear() {
    _timer?.cancel();
    _generation++;
    results = const [];
  }

  /// Searches [text] once typing has paused.
  void schedule(String text) {
    clear();
    _timer = Timer(pause, () => unawaited(_search(text)));
  }

  /// Sends a search still waiting out its pause at once.
  void flush(String text) {
    if (_timer?.isActive ?? false) {
      _timer!.cancel();
      unawaited(_search(text));
    }
  }

  Future<void> _search(String text) async {
    final generation = _generation;
    final hits = await searchTranscriptHits(_read, text, limit: limit);
    if (_disposed || generation != _generation) return;
    results = hits;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
