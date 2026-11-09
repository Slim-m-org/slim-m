// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A conversation's search at phone width: the command palette's own compact
/// shape (a field beside Cancel, a section header, rows) scoped to one
/// channel, in place of the wide panel's bar under the header.
///
/// See `docs/design/desktop-vs-mobile.md`: the layout follows the window's
/// width, and below `kCompactWidth` search is a page of its own, the way the
/// palette is a pull-down there.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../members/providers/user_profiles.dart';
import '../../messages/providers/message_search.dart'
    show matchedAttachmentName;
import '../../messages/providers/message_search_query.dart';
import '../../messages/widgets/author_label.dart';
import '../../messages/widgets/message_row_identity.dart' show formatMessageDay;
import '../../messages/widgets/message_text_spans.dart' show inlineTextSpans;
import '../../palette/widgets/command_palette_compact.dart';
import '../../palette/widgets/command_palette_rows.dart' show paletteRowInset;
import '../../palette/widgets/palette_highlight.dart';

/// The row's own inset: the palette's, less what the focus ring reserves, so
/// the text starts where a palette row's does.
const double _rowInset = paletteRowInset - (focusRingGap + focusRingWidth);

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

/// The hits as palette-style rows, which scroll under the page's pinned
/// scope header.
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

  /// What was typed; any `from:` or `in:` operator is left out of what is marked.
  final String query;
  final ValueChanged<api.Message> onSelect;

  /// See `MessageBody`: what a hit's mentions and emoji are resolved against.
  final Set<String> knownUsernames;
  final Set<String> knownRoleNames;
  final Map<String, String> customEmoji;

  @override
  Widget build(BuildContext context) {
    final terms = parseSearchQuery(query).text;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s8,
        vertical: AppSpacing.s4,
      ),
      itemCount: hits.length,
      itemBuilder: (context, i) => _HitRow(
        key: ValueKey(hits[i].id),
        message: hits[i],
        terms: terms,
        onSelect: onSelect,
        knownUsernames: knownUsernames,
        knownRoleNames: knownRoleNames,
        customEmoji: customEmoji,
      ),
    );
  }
}

/// One hit: who and when above, the message with the match marked, and the
/// file it was found in when the match was not in the text.
///
/// Selects only its own author's slice of [batchProfilesControllerProvider],
/// so an unrelated author resolving does not rebuild every row.
class _HitRow extends ConsumerWidget {
  const _HitRow({
    super.key,
    required this.message,
    required this.terms,
    required this.onSelect,
    required this.knownUsernames,
    required this.knownRoleNames,
    required this.customEmoji,
  });

  final api.Message message;
  final String terms;
  final ValueChanged<api.Message> onSelect;
  final Set<String> knownUsernames;
  final Set<String> knownRoleNames;
  final Map<String, String> customEmoji;

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
    final file = matchedAttachmentName(message);
    final text = message.content;
    return Semantics(
      button: true,
      label: 'Message from $name: ${text.isEmpty ? file ?? '' : text}',
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
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: AppSizes.rowTouch),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: _rowInset,
                  vertical: AppSpacing.s8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: AppSpacing.s4,
                  children: [
                    Row(
                      spacing: AppSpacing.s8,
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: AuthorNameLine(
                              name: name,
                              profile: resolution.profile,
                              style: AppText.ui.copyWith(
                                color: tokens.textPrimary,
                                fontWeight: AppWeights.medium,
                              ),
                            ),
                          ),
                        ),
                        Text(
                          formatMessageDay(message.createdAt),
                          style: AppText.code.copyWith(
                            fontSize: AppText.caption.fontSize,
                            color: tokens.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    if (text.isNotEmpty)
                      _Snippet(
                        text: paletteSnippet(text, terms),
                        terms: terms,
                        knownUsernames: knownUsernames,
                        knownRoleNames: knownRoleNames,
                        customEmoji: customEmoji,
                      ),
                    if (file != null) _FoundIn(file: file, terms: terms),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Says a hit was found inside a file rather than in the message text.
class _FoundIn extends StatelessWidget {
  const _FoundIn({required this.file, required this.terms});

  final String file;
  final String terms;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Row(
      spacing: AppSpacing.s4,
      children: [
        Icon(
          AppIcons.attachFile,
          size: AppSizes.icon12,
          color: tokens.textSecondary,
        ),
        Flexible(
          child: Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'Found in '),
                ...paletteHighlightWordSpans(file, terms),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ),
      ],
    );
  }
}

/// A hit's text on at most two lines, with its emoji and mentions resolved the
/// way the transcript does and the searched words in bold.
class _Snippet extends StatefulWidget {
  const _Snippet({
    required this.text,
    required this.terms,
    required this.knownUsernames,
    required this.knownRoleNames,
    required this.customEmoji,
  });

  final String text;
  final String terms;
  final Set<String> knownUsernames;
  final Set<String> knownRoleNames;
  final Map<String, String> customEmoji;

  @override
  State<_Snippet> createState() => _SnippetState();
}

class _SnippetState extends State<_Snippet> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final style = AppText.ui.copyWith(color: tokens.textPrimary);
    return Text.rich(
      TextSpan(
        style: style,
        children: paletteHighlightInline(
          inlineTextSpans(
            widget.text,
            customEmoji: widget.customEmoji,
            ambientStyle: style,
            linkColor: tokens.accent,
            recognizers: _recognizers,
            knownUsernames: widget.knownUsernames,
            knownRoleNames: widget.knownRoleNames,
          ),
          widget.terms,
        ),
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}
