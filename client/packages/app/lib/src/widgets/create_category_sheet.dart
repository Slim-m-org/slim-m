// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet for making a channel category: a name, sent through
/// `POST /categories` (`SlimmApi.createCategory`).
///
/// Opened from the rail's own right-click menu, beside "Create channel...".
/// Until this existed a category could only be made from Space settings ->
/// Channel categories, which the owner reported as right-clicking the rail
/// and finding only a channel on offer. `create_channel_sheet.dart` is the
/// shape this mirrors; the admin screen keeps its inline form for the
/// manage-many case.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/providers.dart';
import '../ids.dart';
import 'name_entry_sheet.dart';

Future<void> showCreateCategorySheet(BuildContext context) {
  final id = newCategoryId();
  return showAppSheet<void>(
    context,
    builder: (context) => _CreateCategorySheet(id: id),
  );
}

class _CreateCategorySheet extends ConsumerWidget {
  const _CreateCategorySheet({required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NameEntrySheet(
      noun: 'category',
      title: 'Create a category',
      onCreate: (name) async {
        final created = await ref.read(apiProvider).createCategory(name, id: id);
        final store = await ref.read(storeProvider.future);
        await store.upsertCategory(created);
        return null;
      },
    );
  }
}
