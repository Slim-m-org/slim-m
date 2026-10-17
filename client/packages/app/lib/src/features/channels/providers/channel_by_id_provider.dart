// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One channel row by id, watched through the local store.
///
/// Replaces the pattern where several widgets each opened a stream over the
/// whole channels table and filtered to one id in the builder (CS3): every one
/// of them re-ran on any write to any channel. This family watches a single
/// indexed row instead, so a widget rebuilds only when its own channel changes,
/// and riverpod folds identical ids into one shared subscription.
///
/// Returns the raw row, or null when the channel is absent (or the value is not
/// loaded yet, read as `valueOrNull`). It never defaults to a display value,
/// because the call sites disagree on what an absent channel should render -
/// one hides, another shows "a call", another a blank-but-visible bar - so each
/// keeps its own fallback after reading from here.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';

import '../../../providers/providers.dart';

final channelByIdProvider = StreamProvider.autoDispose.family<Channel?, String>((
  ref,
  channelId,
) {
  // Watch the store rather than await its future, the shape the call sites replaced used, so this re-runs when the store resolves instead of holding an async gap the widget-test clock never advances.
  final store = ref.watch(storeProvider).valueOrNull;
  if (store == null) return const Stream.empty();
  return store.watchChannelRow(channelId);
});
