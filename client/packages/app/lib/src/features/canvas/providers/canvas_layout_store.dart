// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The local table of each channel's personal canvas layout. Decision 0082.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';

import '../../../providers/providers.dart';

/// One per account container, because the database file already is.
final canvasLayoutStoreProvider = FutureProvider<CanvasLayoutStore>(
  (ref) async => CanvasLayoutStore(await ref.watch(databaseProvider.future)),
);
