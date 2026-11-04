// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one "choose a member" surface: the command palette's people row in a
/// searchable, keyboard-driven sheet, so every member choice looks the same.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../palette/widgets/command_palette_items.dart'
    show PaletteReason, memberMatchReason, memberMatchesQuery;
import '../../palette/widgets/command_palette_rows.dart' show PaletteRowShell;
import '../../palette/widgets/palette_person_body.dart';
import '../providers/member_presence.dart' show membersProvider;

const _listMaxHeightFraction = 0.6;

/// Opens the picker and resolves to the chosen member, or null if dismissed.
Future<api.UserProfile?> pickMember(BuildContext context) =>
    showAppSheet<api.UserProfile>(
      context,
      builder: (context) => const MemberPicker(),
    );

/// Watches [membersProvider] itself so the list stays alive while open.
class MemberPicker extends ConsumerStatefulWidget {
  const MemberPicker({super.key});

  @override
  ConsumerState<MemberPicker> createState() => _MemberPickerState();
}

class _MemberPickerState extends ConsumerState<MemberPicker> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  int _highlighted = 0;
  List<api.UserProfile> _shown = const [];
  double _rowExtent = AppSizes.controlLg;

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String get _query => _search.text.trim();

  void _move(int delta) {
    if (_shown.isEmpty) return;
    setState(() {
      _highlighted = (_highlighted + delta) % _shown.length;
      if (_highlighted < 0) _highlighted += _shown.length;
    });
    _scrollToHighlighted();
  }

  void _scrollToHighlighted() {
    if (!_scroll.hasClients) return;
    final top = _highlighted * _rowExtent;
    final position = _scroll.position;
    if (top < position.pixels) {
      _scroll.jumpTo(top);
    } else if (top + _rowExtent >
        position.pixels + position.viewportDimension) {
      _scroll.jumpTo(top + _rowExtent - position.viewportDimension);
    }
  }

  void _choose(api.UserProfile member) => Navigator.of(context).pop(member);

  void _chooseHighlighted() {
    if (_shown.isNotEmpty) _choose(_shown[_highlighted]);
  }

  @override
  Widget build(BuildContext context) {
    final members = ref.watch(membersProvider);
    final touch = MediaQuery.sizeOf(context).width < kCompactWidth;
    _rowExtent = touch ? AppSizes.rowTouch : AppSizes.controlLg;
    return SafeArea(
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppSheetHeader(
              'Choose a member',
              padding: EdgeInsets.fromLTRB(
                AppSpacing.s16,
                0,
                AppSpacing.s16,
                AppSpacing.s8,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
              child: AppInput(
                key: const Key('member-picker-input'),
                controller: _search,
                autofocus: !touch,
                placeholder: 'Search members',
                icon: const Icon(AppIcons.search),
                semanticLabel: 'Search members',
                onChanged: (_) => setState(() => _highlighted = 0),
                onSubmitted: (_) => _chooseHighlighted(),
              ),
            ),
            const SizedBox(height: AppSpacing.s8),
            AppAsyncView(
              value: AppAsyncState(
                data: members.valueOrNull,
                error: members.error,
              ),
              errorMessage: 'Could not load members.',
              onRetry: () => ref.invalidate(membersProvider),
              emptyMessage: 'No members yet.',
              isEmpty: (list) => list.isEmpty,
              data: (context, list) => _results(context, list, touch),
            ),
            if (!touch) const _KeyHints(),
          ],
        ),
      ),
    );
  }

  Widget _results(
    BuildContext context,
    List<api.UserProfile> list,
    bool touch,
  ) {
    _shown = [
      for (final member in list)
        if (memberMatchesQuery(member, _query)) member,
    ];
    if (_shown.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.s16),
        child: Text('No members match.'),
      );
    }
    _highlighted = _highlighted.clamp(0, _shown.length - 1);
    final maxHeight =
        MediaQuery.sizeOf(context).height * _listMaxHeightFraction;
    final height = (_shown.length * _rowExtent).clamp(0.0, maxHeight);
    return SizedBox(
      height: height,
      child: ListView.builder(
        key: const Key('member-picker-list'),
        controller: _scroll,
        itemExtent: _rowExtent,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
        itemCount: _shown.length,
        itemBuilder: (context, index) {
          final member = _shown[index];
          final PaletteReason? reason = memberMatchReason(member, _query);
          return PaletteRowShell(
            key: Key('member-picker-row-${member.id}'),
            highlighted: index == _highlighted,
            touch: touch,
            semanticLabel: member.displayName,
            onTap: () => _choose(member),
            child: PalettePersonBody(
              member: member,
              label: member.displayName,
              query: _query,
              reason: reason,
            ),
          );
        },
      ),
    );
  }
}

class _KeyHints extends StatelessWidget {
  const _KeyHints();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final style = AppText.caption.copyWith(color: tokens.textSecondary);
    Widget hint(List<String> keys, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s4,
      children: [
        for (final key in keys) AppKbd(key),
        Text(label, style: style),
      ],
    );
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s16),
      child: Wrap(
        spacing: AppSpacing.s16,
        children: [
          hint(const ['↑', '↓'], 'Move'),
          hint(const ['Enter'], 'Choose'),
        ],
      ),
    );
  }
}
