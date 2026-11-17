// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet for making a channel category: a name and, on a server that
/// nests them (decision 0120), the top-level category it goes inside. Sent
/// through `POST /categories` (`SlimmApi.createCategory`).
///
/// Opened from the rail's own right-click menu, beside "Create channel", and
/// from a top-level header's "Create sub-category...", which picks that
/// header as the parent. `create_channel_sheet.dart` is the shape this mirrors.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../ids.dart';
import '../../../providers/providers.dart';
import '../../../providers/store_stream.dart';
import '../../../widgets/name_entry_sheet.dart';
import '../../settings/widgets/settings_select_row.dart';
import '../providers/category_nesting.dart';
import '../providers/channel_actions.dart';
import 'category_tree.dart';

/// [parentId] starts the sheet inside that top-level category.
Future<void> showCreateCategorySheet(BuildContext context, {String? parentId}) {
  final id = newCategoryId();
  return showAppSheet<void>(
    context,
    builder: (context) => _CreateCategorySheet(id: id, parentId: parentId),
  );
}

/// The parent picker's value for "no parent"; a category id is never empty.
const _topLevel = '';

class _CreateCategorySheet extends ConsumerStatefulWidget {
  const _CreateCategorySheet({required this.id, this.parentId});

  final String id;
  final String? parentId;

  @override
  ConsumerState<_CreateCategorySheet> createState() =>
      _CreateCategorySheetState();
}

class _CreateCategorySheetState extends ConsumerState<_CreateCategorySheet> {
  late String _parent = widget.parentId ?? _topLevel;
  final _categories = StoreStream<List<ChannelCategoryRow>>(
    (s) => s.watchCategories(),
  );

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(categoriesNestProvider)
        ? ref.watch(storeProvider).valueOrNull
        : null;
    if (store == null) return _sheet(const []);
    return StreamBuilder<List<ChannelCategoryRow>>(
      stream: _categories.of(store),
      builder: (context, snapshot) => _sheet([
        for (final c in CategoryTree(snapshot.data ?? const []).topLevel)
          if (c.parentId == null) c,
      ]),
    );
  }

  Widget _sheet(List<ChannelCategoryRow> parents) {
    final sub = _parent != _topLevel;
    return NameEntrySheet(
      noun: 'category',
      title: sub ? 'Create a sub-category' : 'Create a category',
      onCreate: (name) async {
        await ref
            .read(channelActionsProvider)
            .createCategory(
              name,
              id: widget.id,
              parentId: sub ? _parent : null,
            );
        return null;
      },
      extraFields: [
        if (parents.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s8),
          SettingsSelectRow<String>(
            label: 'Parent category',
            value: _parent,
            choices: [
              const SettingsChoice(value: _topLevel, label: 'None'),
              for (final parent in parents)
                SettingsChoice(value: parent.id, label: parent.name),
            ],
            onChanged: (value) => setState(() => _parent = value),
          ),
        ],
      ],
    );
  }
}
