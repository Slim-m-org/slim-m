// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How the call's audio is doing, for the call tiles and the Troubleshooting page.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller.dart';

/// Mirrors a [ValueListenable] as provider state.
class ListenableState<T> extends StateNotifier<T> {
  ListenableState(this._source) : super(_source.value) {
    _source.addListener(_sync);
  }

  final ValueListenable<T> _source;

  void _sync() => state = _source.value;

  @override
  void dispose() {
    _source.removeListener(_sync);
    super.dispose();
  }
}

/// Identities whose audio is breaking up right now; empty while all is well.
final poorConnectionsProvider =
    StateNotifierProvider<ListenableState<Set<String>>, Set<String>>(
      (ref) => ListenableState(
        ref.watch(voiceControllerProvider.notifier).health.poorConnections,
      ),
    );

/// The last finished call's numbers, or null before any call has ended.
final lastCallHealthProvider =
    StateNotifierProvider<
      ListenableState<CallHealthSummary?>,
      CallHealthSummary?
    >(
      (ref) => ListenableState(
        ref.watch(voiceControllerProvider.notifier).health.lastCall,
      ),
    );
