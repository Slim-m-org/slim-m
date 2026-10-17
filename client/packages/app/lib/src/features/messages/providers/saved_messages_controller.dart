// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The caller's own saved messages, fetched on demand.
///
/// Not a stream off the local store the way the transcript is: a saved list
/// spans channels and is filtered server-side by what the reader can see
/// *now*, which is a judgement only the server can make. Caching it locally
/// would mean holding a list that quietly goes wrong the moment somebody's
/// access changes, so this asks each time the sheet opens.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

/// Reloads on every watch, which is once per sheet open - `autoDispose` drops
/// it again as soon as the sheet closes, so a list left open in another
/// session is never what a later one is shown.
final savedMessagesProvider =
    FutureProvider.autoDispose<List<api.SavedMessage>>(
      (ref) => ref.watch(apiProvider).listSavedMessages(),
    );
