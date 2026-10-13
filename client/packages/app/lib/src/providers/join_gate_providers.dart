// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The join gate: the rules every member reads, and the admin's settings.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'providers.dart';

/// The rules and whether this account still has to accept them. Null from a
/// server too old to have a gate, so nobody is ever shown a gate it lacks.
final spaceRulesProvider = FutureProvider.autoDispose<api.SpaceRules?>((
  ref,
) async {
  try {
    return await ref.watch(apiProvider).spaceRules();
  } on api.NotFoundException {
    return null;
  }
});

/// The admin's view of the gate; requires MANAGE_SERVER.
final joinGateProvider = FutureProvider.autoDispose<api.JoinGate>(
  (ref) => ref.watch(apiProvider).joinGate(),
);
