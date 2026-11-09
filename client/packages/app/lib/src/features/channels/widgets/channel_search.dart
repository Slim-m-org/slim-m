// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The inline panel the channel header's search toggle reveals: a query
/// field over the real full-text search endpoint, and its results in place
/// of the live message list while open.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import '../../messages/providers/message_search.dart'
    show matchedAttachmentName;
import 'package:slimm_design_system/design_system.dart';

import '../../settings/providers/display_density.dart';
import '../../members/providers/user_profiles.dart';
import '../../messages/widgets/author_label.dart';
import '../../messages/widgets/message_text.dart';
import '../../palette/widgets/command_palette_rows.dart'
    show PaletteSectionHeader;
import 'compact_channel_search.dart';

class ChannelSearchBar extends StatelessWidget {
  const ChannelSearchBar({
    super.key,
    required this.controller,
    required this.onChanged,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

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
            maxLength: api.InputLimits.searchQuery,
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
    this.seeking = false,
    this.banner,
    this.compact = false,
    this.query,
    this.scope = '',
  });

  /// Exposed so a test can find this exact node rather than any other
  /// `Semantics` widget an ancestor happens to build.
  static const Key liveRegionKey = Key('channel_search_results_announcer');

  /// Null before the first reply and after a failure; only an empty (not
  /// null) list means the search genuinely came back with nothing. While a
  /// newer query loads this still holds the last one's hits.
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

  /// A tapped hit is still being found, which can take several pages.
  final bool seeking;

  /// Why a tapped hit could not be opened, above the hits so another can be tried.
  final Widget? banner;

  /// The phone's page: palette rows under a header naming [scope], and a hint
  /// in place of hits while nothing has been typed.
  final bool compact;

  /// What was last searched for, null before anything is; only a page that is
  /// open with an empty field leaves this unset.
  final String? query;

  /// What is being searched, such as "#general", for the compact header.
  final String scope;

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
        if (compact)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
            child: PaletteSectionHeader(label: 'Messages in $scope'),
          ),
        // Revealed rather than inserted, so a hit that is found at once never flashes the line.
        AppRevealBand(
          child: seeking || banner != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (seeking) const _SeekingLine(),
                    if (banner != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.s16,
                          AppSpacing.s8,
                          AppSpacing.s16,
                          0,
                        ),
                        child: banner,
                      ),
                  ],
                )
              : null,
        ),
        Expanded(child: _body(context, ref, tokens)),
      ],
    );
  }

  /// What a screen reader should hear once this state settles: a result
  /// count, an honest "no matches", or why nothing came back.
  String _announcement() {
    if (compact && query == null) return '';
    if (seeking) return 'Finding that message.';
    if (loading) return 'Searching messages.';
    if (failed) {
      return forbidden
          ? 'You do not have permission to search this channel.'
          : 'Search failed.';
    }
    final count = results?.length ?? 0;
    if (count == 0) return 'No matches.';
    final noun = count == 1 ? 'result' : 'results';
    return '$count $noun found.';
  }

  Widget _body(BuildContext context, WidgetRef ref, AppTokens tokens) {
    if (compact && query == null) {
      return Center(
        child: Text(
          'Type to search.',
          style: TextStyle(color: tokens.textSecondary),
        ),
      );
    }
    if (loading && (results?.isEmpty ?? true)) {
      return const Center(child: AppSpinner(size: AppSpinnerSize.lg));
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
    if (compact) {
      return CompactSearchHits(
        hits: list,
        query: query ?? '',
        onSelect: onSelect,
        knownUsernames: knownUsernames,
        knownRoleNames: knownRoleNames,
        customEmoji: customEmoji,
      );
    }
    final density = ref.watch(messageDensityControllerProvider);
    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.s16),
      itemCount: list.length,
      separatorBuilder: (_, __) => SizedBox(height: density.listRowGap),
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

/// Shown while a tapped hit's message is paged in, so the tap has a result.
class _SeekingLine extends StatelessWidget {
  const _SeekingLine();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s16,
        vertical: AppSpacing.s8,
      ),
      child: Row(
        children: [
          const AppSpinner(size: AppSpinnerSize.sm),
          const SizedBox(width: AppSpacing.s8),
          Text(
            'Finding that message',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ],
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
              padding: EdgeInsets.symmetric(
                horizontal: AppSpacing.s4,
                vertical: ref.watch(messageDensityControllerProvider).hitInset,
              ),
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
                  if (message.content.isNotEmpty)
                    MessageBody(
                      content: message.content,
                      knownUsernames: knownUsernames,
                      knownRoleNames: knownRoleNames,
                      customEmoji: customEmoji,
                    ),
                  if (matchedAttachmentName(message) case final file?)
                    _AttachmentMatchLine(file: file),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Says a hit was found inside a file rather than in the message text.
class _AttachmentMatchLine extends StatelessWidget {
  const _AttachmentMatchLine({required this.file});

  final String file;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s4),
      child: Row(
        children: [
          Icon(AppIcons.attachFile, size: 12, color: tokens.textSecondary),
          const SizedBox(width: AppSpacing.s4),
          Flexible(
            child: Text(
              'Found in $file',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
