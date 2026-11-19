// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The command palette: a search over channels, members, messages and
/// actions, opened by `Ctrl K` or by tapping the rail's search field, and the
/// app's one message search: a conversation's search button opens it with
/// that conversation as an `in:` filter. Filters (docs/search.md) are typed
/// with autocomplete and sit as chips under the field; with any chip the
/// palette searches messages only.
///
/// Renders differently by window width, per `docs/design/desktop-vs-mobile.md`
/// pattern pair 3 ("Command palette -> pull-down"): a floating card above
/// `kCompactWidth`, and below it `CommandPaletteCompactShell`'s full-bleed
/// panel pinned to the top of the window, with an on-screen Cancel button
/// standing in for Escape - a touch device has no key for that at all. The
/// search field, the result ranking and every row are the one shared
/// implementation in this file; only the shell around them differs, chosen
/// live off `MediaQuery` rather than off `Platform`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../../providers/admin_providers.dart';
import '../../../routing/modal_page.dart';
import '../../../widgets/run_guarded.dart';
import '../../members/providers/member_presence.dart' show membersProvider;
import '../../members/providers/presence_view.dart' show aroundUserIdsProvider;
import '../../messages/providers/message_search_query.dart';
import '../../voice/providers/transcript_search.dart';
import '../../../providers/providers.dart';
import '../../../providers/store_stream.dart';
import '../../members/providers/user_profiles.dart';
import '../../channels/widgets/channel_rail.dart' show selectedChannelId;
import '../../channels/widgets/category_tree.dart' show categoryPaths;
import '../providers/palette_message_search.dart';
import '../providers/palette_query.dart';
import 'command_palette_compact.dart';
import 'command_palette_items.dart';
import 'command_palette_results.dart';
import 'command_palette_sections.dart';
import 'command_palette_rows.dart';
import 'palette_filter_chips.dart';
import 'palette_filter_suggestions.dart';
import 'palette_transcript_items.dart';
import '../../../widgets/rise_fade_transition.dart';
import '../../members/providers/mention_names.dart' show mentionNamesProvider;

/// The design's floating card width; not on the spacing grid because it is
/// the palette's own measured size, like the rail widths beside it. Never
/// clamped against the viewport: [_CommandPaletteContentState.build] only
/// reaches this width at or above `kCompactWidth` (600), where `width - 48`
/// is always past it, and below that width the compact shell replaces the
/// card outright rather than shrinking it.
const double _paletteWidth = 600;
const double _resultsMaxHeight = 420;

/// How many message hits a filtered search fetches at a time.
const int paletteMessagePage = 25;

/// Opens the palette over whatever is on screen and restores focus to
/// wherever it was once the palette closes. Message search covers every
/// channel the caller can view unless [scope] names one as an `in:` chip;
/// that conversation, or else the open channel, is passed through only so a
/// hit in it jumps in place instead of navigating to itself.
Future<void> openCommandPalette(
  BuildContext context, {
  SearchFilter? scope,
}) async {
  final previousFocus = FocusManager.instance.primaryFocus;
  final channelId = scope?.channelId ?? selectedChannelId(context);

  await showGeneralDialog<void>(
    context: context,
    barrierLabel: 'Command palette',
    barrierDismissible: true,
    barrierColor: kScrimColor,
    // The same 180ms AppMotion.base `modalPage` and `showAppSheet` use.
    transitionDuration: AppMotion.reduced(context, AppMotion.base),
    pageBuilder: (context, animation, secondaryAnimation) => Semantics(
      namesRoute: true,
      scopesRoute: true,
      explicitChildNodes: true,
      label: 'Command palette',
      child: _CommandPaletteContent(currentChannelId: channelId, scope: scope),
    ),
    // member_profile.dart's authored entrance: a curved fade with an 8px rise.
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        RiseFadeTransition(animation: animation, rise: 8, child: child),
  );

  // The dialog may have outlived whatever held focus before it opened, so only
  // claim it back if it is still attached to something that can take it.
  if (previousFocus != null && previousFocus.context != null) {
    previousFocus.requestFocus();
  }
}

class _CommandPaletteContent extends ConsumerStatefulWidget {
  const _CommandPaletteContent({required this.currentChannelId, this.scope});

  final String? currentChannelId;
  final SearchFilter? scope;

  @override
  ConsumerState<_CommandPaletteContent> createState() =>
      _CommandPaletteContentState();
}

class _CommandPaletteContentState extends ConsumerState<_CommandPaletteContent>
    with GuardedActionState<_CommandPaletteContent> {
  late final _field = PaletteField(
    filters: [?widget.scope],
    onEdited: _onEdited,
  );
  final _channels = StoreStream<List<Channel>>((s) => s.watchChannels());
  final _categories = StoreStream<List<ChannelCategoryRow>>(
    (s) => s.watchCategories(),
  );
  late final _messages = PaletteMessageSearch(ref.read)
    ..addListener(_onMessages);
  String _query = '';
  int _highlighted = 0;
  List<api.TranscriptHit> _transcriptResults = const [];

  /// Retires a transcript search still in flight when the query moves on.
  int _transcriptGeneration = 0;

  /// The last frame's flat result list, so a key handler (which runs outside
  /// build) can act on exactly what the user is looking at right now.
  List<PaletteResultItem> _visible = const [];

  /// Where each section begins in [_visible], for Tab to jump between them.
  List<int> _sectionStarts = const [];

  /// Set while a chosen result runs, so a second Enter or tap cannot start it again.
  bool _running = false;

  @override
  void dispose() {
    _messages.dispose();
    _field.dispose();
    super.dispose();
  }

  void _onMessages() => setState(() {});

  /// With chips the palette is a message search, and nothing else.
  bool get _filtering => _field.filters.isNotEmpty;

  bool get _typingValue => _field.typingValue;

  /// Puts [prefix] in front of the query, as if typed, to list one section whole.
  void _scopeTo(String prefix) =>
      _field.setText('$prefix${parsePaletteQuery(_query).text}');

  void _onEdited() {
    setState(() {
      _query = _field.text;
      _highlighted = 0;
    });
    clearActionError();
    _search();
  }

  void _search() {
    _transcriptGeneration++;
    _transcriptResults = const [];
    if (_typingValue) {
      _messages.clear();
    } else if (_filtering) {
      final parsed = parseSearchQuery(_query, filters: _field.filters);
      final scopeOnly =
          parsed.text.isEmpty &&
          parsed.filters.every((f) => f.key == SearchKey.inChannel);
      if (scopeOnly) {
        _messages.clear();
      } else {
        unawaited(_messages.run(parsed, limit: paletteMessagePage));
      }
    } else {
      final text = parsePaletteQuery(_query);
      if (text.text.isEmpty || text.scope != PaletteScope.all) {
        _messages.clear();
      } else {
        unawaited(
          _messages.run(parseSearchQuery(text.text), limit: paletteResultLimit),
        );
        unawaited(_searchTranscripts(text.text));
      }
    }
  }

  Future<void> _searchTranscripts(String query) async {
    final generation = _transcriptGeneration;
    final hits = await searchTranscriptHits(
      ref.read,
      query,
      limit: paletteResultLimit,
    );
    if (!mounted || generation != _transcriptGeneration) return;
    setState(() => _transcriptResults = hits);
  }

  void _close() => Navigator.of(context).pop();

  void _move(int delta) {
    if (_visible.isEmpty) return;
    setState(() {
      _highlighted = (_highlighted + delta) % _visible.length;
      if (_highlighted < 0) _highlighted += _visible.length;
    });
  }

  /// Tab completes a highlighted suggestion; anywhere else it moves between sections.
  void _tab(int direction) {
    final item = _visible.elementAtOrNull(_highlighted);
    if (direction > 0 && item?.kind == PaletteKind.filter) {
      _run(item!);
      return;
    }
    if (_sectionStarts.length < 2) return;
    final current = _sectionStarts.lastIndexWhere(
      (start) => start <= _highlighted,
    );
    final next = (current + direction) % _sectionStarts.length;
    setState(
      () => _highlighted =
          _sectionStarts[next < 0 ? next + _sectionStarts.length : next],
    );
  }

  Future<void> _runHighlighted() async {
    if (_visible.isEmpty) return;
    await _run(_visible[_highlighted]);
  }

  Future<void> _run(PaletteResultItem item) async {
    if (_running) return;
    _running = true;
    try {
      final done = await guard(
        whatFailed: item.kind == PaletteKind.person
            ? 'message ${item.label}'
            : 'open that result',
        action: () => item.onSelect(context, ref),
      );
      final stays = item.showsAllOf != null || item.keepsOpen;
      if (done && mounted && !stays) Navigator.of(context).pop();
    } finally {
      _running = false;
    }
  }

  Map<ShortcutActivator, VoidCallback> _bindings() {
    final close = activatorFor(AppAction.escape);
    return {
      const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
      const SingleActivator(LogicalKeyboardKey.tab): () => _tab(1),
      const SingleActivator(LogicalKeyboardKey.tab, shift: true): () =>
          _tab(-1),
      if (close != null) close: () => Navigator.of(context).pop(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final storeAsync = ref.watch(storeProvider);
    final members = ref.watch(membersProvider).valueOrNull ?? const [];
    final me = ref.watch(meProvider).valueOrNull;
    final permissions = ref.watch(myPermissionsProvider);
    // Re-read every build, so a resize crossing it while open swaps shells live.
    final compact = MediaQuery.sizeOf(context).width < kCompactWidth;
    final label = _filtering
        ? 'Search messages'
        : 'Search channels, people and messages';

    final input = AppInput(
      maxLength: api.InputLimits.searchQuery,
      key: const Key('command-palette-input'),
      controller: _field.controller,
      focusNode: _field.focusNode,
      autofocus: true,
      size: compact ? AppInputSize.lg : AppInputSize.md,
      placeholder: label,
      icon: Icon(
        AppIcons.search,
        size: AppSizes.icon16,
        color: tokens.textSecondary,
      ),
      onChanged: (_) => _field.typed(),
      onSubmitted: (_) => _runHighlighted(),
      semanticLabel: label,
      trailing: compact ? null : PaletteEscKeycap(onTap: _close),
    );
    final chips = !_filtering
        ? null
        : PaletteFilterChips(
            filters: _field.filters,
            onRemove: _field.remove,
            touch: compact,
          );

    final list = storeAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => const SizedBox.shrink(),
      data: (store) => StreamBuilder<List<Channel>>(
        stream: _channels.of(store),
        builder: (context, snapshot) {
          final channels = snapshot.data ?? const <Channel>[];
          // The category names ride a second stream so a rename shows live.
          return StreamBuilder<List<ChannelCategoryRow>>(
            stream: _categories.of(store),
            builder: (context, categorySnapshot) => _animatedResults((
              channels: channels,
              categoryNames: categoryPaths(
                categorySnapshot.data ?? const <ChannelCategoryRow>[],
              ),
              members: members,
              me: me,
              permissions: permissions,
              compact: compact,
            )),
          );
        },
      ),
    );

    final results = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        list,
        if (actionError case final failure?)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s8),
            child: AppErrorState(message: failure, onDismiss: clearActionError),
          ),
      ],
    );

    final shell = compact
        ? CommandPaletteCompactShell(
            searchField: input,
            chips: chips,
            results: results,
            onCancel: _close,
          )
        : Align(
            alignment: const Alignment(0, -0.5),
            child: Material(
              type: MaterialType.transparency,
              child: AppMenu(
                width: _paletteWidth,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.s8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      spacing: AppSpacing.s8,
                      children: [input, ?chips],
                    ),
                  ),
                  const AppMenuDivider(),
                  results,
                  const AppMenuDivider(),
                  PaletteFooter(filtering: _filtering),
                ],
              ),
            ),
          );

    return CallbackShortcuts(bindings: _bindings(), child: shell);
  }

  Widget _animatedResults(_ResultInputs inputs) {
    // Keyed on the query and chips: arrow keys and late-arriving message hits update in place, only typing crossfades.
    return MaybeAnimatedSize(
      duration: AppMotion.fast,
      curve: AppMotion.entrance,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: AppMotion.reduced(context, AppMotion.fast),
        switchInCurve: AppMotion.entrance,
        switchOutCurve: AppMotion.exit,
        child: KeyedSubtree(
          key: ValueKey('$_query ${_field.filters.join(' ')}'),
          child: _buildResults(inputs),
        ),
      ),
    );
  }

  List<PaletteResultItem> _suggestions(_ResultInputs inputs) =>
      filterSuggestions(
        _field.word,
        offerKeys: _filtering,
        sources: (
          members: inputs.members,
          channels: inputs.channels,
          today: DateTime.now(),
        ),
        actions: (complete: _field.completeKey, add: _field.add),
      );

  List<PaletteSection> _sections(_ResultInputs inputs) {
    final channelsById = {for (final c in inputs.channels) c.id: c};
    final query = parsePaletteQuery(_query).text;
    return paletteSections((
      query: _query,
      filtering: _filtering,
      typingValue: _typingValue,
      suggestions: _suggestions(inputs),
      suggestionsLabel: filterSuggestionsLabel(_field.word),
      messages: _messages,
      messageItems: buildMessageItems(
        _messages.results,
        currentChannelId: widget.currentChannelId,
        channelsById: channelsById,
        mentionNames: ref.watch(mentionNamesProvider),
      ),
      channels: channelSections(
        inputs.channels,
        query,
        selfDisplayName: inputs.me?.displayName,
        categoryNames: inputs.categoryNames,
        currentChannelId: widget.currentChannelId,
        showAll: parsePaletteQuery(_query).scope == PaletteScope.all
            ? () => _scopeTo('#')
            : null,
      ),
      people: buildMemberItems(
        inputs.members,
        query,
        inputs.me?.id,
        around: ref.watch(aroundUserIdsProvider),
      ),
      transcripts: buildTranscriptItems(
        _transcriptResults,
        channelsById: channelsById,
      ),
      actions: buildActionItems(query, inputs.permissions),
    ));
  }

  Widget _buildResults(_ResultInputs inputs) {
    resolveAuthorProfiles(ref, _messages.results.map((m) => m.authorId));
    final query = _filtering ? _query : parsePaletteQuery(_query).text;
    final sections = _sections(inputs);
    _visible = [for (final section in sections) ...section.items];
    final starts = <int>[];
    var at = 0;
    for (final section in sections) {
      starts.add(at);
      at += section.items.length;
    }
    _sectionStarts = starts;
    if (_highlighted >= _visible.length) {
      _highlighted = _visible.isEmpty ? 0 : _visible.length - 1;
    }
    // A refusal is not an empty result; it is said where the messages would be.
    final asked =
        _filtering ||
        query.isNotEmpty && parsePaletteQuery(_query).scope == PaletteScope.all;
    return PaletteResultsList(
      sections: sections,
      highlighted: _highlighted,
      query: query,
      compact: inputs.compact,
      maxHeight: inputs.compact
          ? MediaQuery.sizeOf(context).height * 0.7
          : _resultsMaxHeight,
      onRun: _run,
      notice: (
        forbidden: asked && _messages.forbidden,
        failed: _messages.failed && !_typingValue,
        retry: () => _messages.retry(),
        announcement: paletteAnnouncement(_messages, _filtering, query),
      ),
    );
  }
}

/// Everything the results list is built from, bundled so two builders share it.
typedef _ResultInputs = ({
  List<Channel> channels,
  Map<String, String> categoryNames,
  List<api.UserProfile> members,
  api.Me? me,
  int permissions,
  bool compact,
});
