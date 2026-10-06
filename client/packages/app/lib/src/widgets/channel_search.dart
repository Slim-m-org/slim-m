// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The inline panel the channel header's search toggle reveals: a query
/// field over the real full-text search endpoint, and its results in place
/// of the live message list while open.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/user_profiles.dart';
import 'author_label.dart';
import 'message_text.dart';

class ChannelSearchBar extends StatelessWidget {
  const ChannelSearchBar({
    super.key,
    required this.controller,
    required this.onChanged,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  /// The operators `parseSearchQuery` (`providers/message_search_query.dart`)
  /// recognises, named here rather than left for someone to discover by
  /// trial or by reading this feature's own PR.
  static const operatorHint =
      'Try from:name, in:channel, has:attachment, has:link, '
      'before:YYYY-MM-DD, after:YYYY-MM-DD';

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s16,
        vertical: AppSpacing.s8,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppInput(
            controller: controller,
            placeholder: 'Search this channel',
            icon: Icon(
              AppIcons.search,
              size: AppSizes.icon16,
              color: tokens.textSecondary,
            ),
            autofocus: true,
            onChanged: onChanged,
            semanticLabel: 'Search this channel',
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(
            operatorHint,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ],
      ),
    );
  }
}

class ChannelSearchResults extends ConsumerWidget {
  const ChannelSearchResults({
    super.key,
    required this.results,
    required this.knownUsernames,
    this.knownRoleNames = const {},
    this.customEmoji = const {},
    required this.loading,
    required this.failed,
    required this.forbidden,
    required this.onRetry,
    required this.onSelect,
  });

  /// Exposed so a test can find this exact node rather than any other
  /// `Semantics` widget an ancestor happens to build.
  static const Key liveRegionKey = Key('channel_search_results_announcer');

  /// Null while loading or after a failure; only an empty (not null) list
  /// means the search genuinely came back with nothing.
  final List<api.Message>? results;
  final Set<String> knownUsernames;

  /// See [MessageBody.knownRoleNames].
  final Set<String> knownRoleNames;

  /// The deployment's custom emoji, name to id. See [MessageBody].
  final Map<String, String> customEmoji;
  final bool loading;

  /// A search that errored. Kept apart from [results] being empty, which
  /// otherwise reads identically to a real "no matches".
  final bool failed;

  /// A 403: retrying the same query will not succeed, so no retry is offered.
  final bool forbidden;
  final VoidCallback onRetry;

  /// Jumps the transcript to a tapped hit.
  final ValueChanged<api.Message> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // Column+Expanded not Stack: the caller hands tight constraints, and a Stack given loose ones shrinks to the zero-size announcer and blanks the panel.
    return Column(
      children: [
        // Invisible live region: the one place "the search ran, here is the outcome" reaches a screen reader, since the panel shows no visible summary.
        Semantics(
          key: liveRegionKey,
          liveRegion: true,
          label: _announcement(),
          child: const SizedBox.shrink(),
        ),
        Expanded(child: _body(context, ref, tokens)),
      ],
    );
  }

  /// What a screen reader should hear once this state settles: a result
  /// count, an honest "no matches", or why nothing came back.
  String _announcement() {
    if (loading) return 'Searching messages.';
    if (failed) {
      return forbidden
          ? 'You do not have permission to search this channel.'
          : 'Search failed.';
    }
    final count = results?.length ?? 0;
    return count == 0
        ? 'No matches.'
        : '$count ${count == 1 ? 'result' : 'results'} found.';
  }

  Widget _body(BuildContext context, WidgetRef ref, AppTokens tokens) {
    if (loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s16),
          child: AppErrorState(
            message: forbidden
                ? 'You do not have permission to search this channel.'
                : 'Search failed.',
            onRetry: forbidden ? null : onRetry,
          ),
        ),
      );
    }
    final list = results ?? const <api.Message>[];
    if (list.isEmpty) {
      return Center(
        child: Text(
          'No matches.',
          style: TextStyle(color: tokens.textSecondary),
        ),
      );
    }
    resolveAuthorProfiles(ref, list.map((m) => m.authorId));
    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.s16),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.s12),
      itemBuilder: (context, i) => SearchResultRow(
        message: list[i],
        knownUsernames: knownUsernames,
        knownRoleNames: knownRoleNames,
        customEmoji: customEmoji,
        onSelect: onSelect,
      ),
    );
  }
}

/// One search hit: selects only its own author's slice of
/// [batchProfilesControllerProvider], so an unrelated author resolving does
/// not rebuild every row in the list - see `message_row_identity.dart`.
class SearchResultRow extends ConsumerWidget {
  const SearchResultRow({
    super.key,
    required this.message,
    required this.knownUsernames,
    this.knownRoleNames = const {},
    required this.customEmoji,
    required this.onSelect,
  });

  final api.Message message;
  final Set<String> knownUsernames;

  /// See [MessageBody.knownRoleNames].
  final Set<String> knownRoleNames;
  final Map<String, String> customEmoji;
  final ValueChanged<api.Message> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final resolution = ref.watch(
      batchProfilesControllerProvider.select(
        (m) => authorResolution(m, message.authorId ?? ''),
      ),
    );
    final name = authorLabelResolved(
      authorId: message.authorId,
      cachedDisplayName: message.authorDisplayName,
      resolution: resolution,
    );
    return Semantics(
      button: true,
      label: 'Message from $name: ${message.content}',
      onTap: () => onSelect(message),
      child: ExcludeSemantics(
        child: AppFocusRing(
          radius: AppRadii.control,
          builder: (context, onFocusChange) => InkWell(
            onTap: () => onSelect(message),
            // AppFocusRing replaces this overlay; see its own doc comment.
            focusColor: Colors.transparent,
            onFocusChange: onFocusChange,
            borderRadius: BorderRadius.circular(AppRadii.control),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AuthorNameLine(
                    name: name,
                    profile: resolution.profile,
                    style: AppText.ui.copyWith(
                      color: tokens.textPrimary,
                      fontWeight: AppWeights.semi,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  MessageBody(
                    content: message.content,
                    knownUsernames: knownUsernames,
                    knownRoleNames: knownRoleNames,
                    customEmoji: customEmoji,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
