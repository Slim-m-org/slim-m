// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The kept uplink measurements, `GET /space/uplink-test`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

final uplinkTestsProvider = FutureProvider.autoDispose<List<api.UplinkTest>>(
  (ref) => ref.watch(apiProvider).fetchUplinkTests(),
);
