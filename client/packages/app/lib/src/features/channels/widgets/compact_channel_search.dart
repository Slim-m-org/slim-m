// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A conversation's search at phone width: the command palette's own compact
/// shape (a field beside Cancel, a section header, rows) scoped to one
/// channel, in place of the wide panel's bar under the header.
///
/// See `docs/design/desktop-vs-mobile.md`: the layout follows the window's
/// width, and below `kCompactWidth` search is a page of its own, the way the
/// palette is a pull-down there.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../members/providers/user_profiles.dart';
import '../../messages/providers/message_search_query.dart';
import '../../messages/widgets/author_label.dart';
import '../../palette/widgets/command_palette_compact.dart';
import '../../palette/widgets/command_palette_items.dart';
import '../../palette/widgets/command_palette_rows.dart';
import '../providers/channel_by_id_provider.dart';

/// What a search is called on its page: "#general", "this thread", "this
/// conversation" for a person or group.
String channelSearchScope({
  required String? name,
  required bool isVoice,
  required bool isThread,
}) {
  if (isThread) return 'this thread';
  if (name == null || name.isEmpty) return 'this conversation';
  return isVoice ? name : '#$name';
}

/// What [query] searched: the channel its `in:` operator names, else [scope].
String searchedScope(String scope, String? query) {
  final named = query == null ? null : parseSearchQuery(query).inChannel;
  return named == null ? scope : '#$named';
}

/// The page's top: the field and Cancel on the palette's raised surface, over a
/// full-width hairline.
class CompactChannelSearchBar extends StatelessWidget {
  const CompactChannelSearchBar({
    super.key,
    required this.controller,
    required this.scope,
    required this.onChanged,
    required this.onSubmitted,
    required this.onCancel,
  });

  static const cancelKey = Key('channel-search-cancel');

  final TextEditingController controller;
  final String scope;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final label = 'Search $scope';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: PaletteCompactSearchRow(
          divider: false,
          cancelKey: cancelKey,
          onCancel: onCancel,
          searchField: AppInput(
            maxLength: api.InputLimits.searchQuery,
            controller: controller,
            size: AppInputSize.lg,
            placeholder: label,
            icon: Icon(
              AppIcons.search,
              size: AppSizes.icon16,
              color: tokens.textSecondary,
            ),
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: onChanged,
            onSubmitted: onSubmitted,
            semanticLabel: label,
          ),
        ),
      ),
    );
  }
}

/// The hits as the command palette's own message rows, which scroll under the
/// page's pinned scope header.
class CompactSearchHits extends StatelessWidget {
  const CompactSearchHits({
    super.key,
    required this.hits,
    required this.query,
    required this.onSelect,
    required this.knownUsernames,
    required this.knownRoleNames,
    required this.customEmoji,
  });

  final List<api.Message> hits;

  /// What was typed; the row leaves any `from:` or `in:` operator out of what it marks.
  final String query;
  final ValueChanged<api.Message> onSelect;

  /// See `MessageBody`: what a hit's mentions and emoji are resolved against.
  final Set<String> knownUsernames;
  final Set<String> knownRoleNames;
  final Map<String, String> customEmoji;

  @override
  Widget build(BuildContext context) => ListView.builder(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.s8,
      vertical: AppSpacing.s4,
    ),
    itemCount: hits.length,
    itemBuilder: (context, i) => _Hit(
      key: ValueKey(hits[i].id),
      message: hits[i],
      query: query,
      onSelect: onSelect,
      knownUsernames: knownUsernames,
      knownRoleNames: knownRoleNames,
      customEmoji: customEmoji,
    ),
  );
}

/// One hit: a palette message row that names the channel it came from, that a
/// screen reader announces with its author, and that a keyboard can open.
///
/// Selects only its own author's slice of [batchProfilesControllerProvider],
/// so an unrelated author resolving does not rebuild every row.
class _Hit extends ConsumerStatefulWidget {
  const _Hit({
    super.key,
    required this.message,
    required this.query,
    required this.onSelect,
    required this.knownUsernames,
    required this.knownRoleNames,
    required this.customEmoji,
  });

  final api.Message message;
  final String query;
  final ValueChanged<api.Message> onSelect;
  final Set<String> knownUsernames;
  final Set<String> knownRoleNames;
  final Map<String, String> customEmoji;

  @override
  ConsumerState<_Hit> createState() => _HitState();
}

class _HitState extends ConsumerState<_Hit> {
  bool _focused = false;

  void _open() => widget.onSelect(widget.message);

  @override
  Widget build(BuildContext context) {
    final channel = ref.watch(
      channelByIdProvider(
        widget.message.channelId,
      ).select((row) => row.valueOrNull),
    );
    final authorId = widget.message.authorId;
    final resolution = ref.watch(
      batchProfilesControllerProvider.select(
        (m) => authorResolution(m, authorId ?? ''),
      ),
    );
    return FocusableActionDetector(
      onShowFocusHighlight: (focused) => setState(() => _focused = focused),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _open();
            return null;
          },
        ),
      },
      child: PaletteResultRow(
        item: messageResultItem(
          widget.message,
          channelLabel: paletteChannelLabel(channel),
          authorName: authorLabelResolved(
            authorId: authorId,
            cachedDisplayName: widget.message.authorDisplayName,
            resolution: resolution,
          ),
          onSelect: (_, _) async => _open(),
        ),
        query: widget.query,
        highlighted: _focused,
        touch: true,
        onTap: _open,
        knownUsernames: widget.knownUsernames,
        knownRoleNames: widget.knownRoleNames,
        customEmoji: widget.customEmoji,
      ),
    );
  }
}
