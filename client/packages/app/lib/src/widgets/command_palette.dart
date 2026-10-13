// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The command palette: a search over channels, members, messages and
/// actions, opened by `Ctrl K` or by tapping the rail's search field.
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../providers/admin_providers.dart';
import '../routing/modal_page.dart';
import '../providers/member_presence.dart' show membersProvider;
import '../providers/message_search.dart';
import '../providers/personal_space_visibility.dart';
import '../providers/providers.dart';
import '../providers/user_profiles.dart';
import 'channel_rail.dart' show selectedChannelId;
import 'command_palette_compact.dart';
import 'command_palette_items.dart';

/// The design's floating card width; not on the spacing grid because it is
/// the palette's own measured size, like the rail widths beside it. Never
/// clamped against the viewport: [_CommandPaletteContentState.build] only
/// reaches this width at or above `kCompactWidth` (600), where `width - 48`
/// is always past it, and below that width the compact shell replaces the
/// card outright rather than shrinking it.
const double _paletteWidth = 480;
const double _resultsMaxHeight = 360;

/// Opens the palette over whatever is on screen and restores focus to
/// wherever it was once the palette closes. Message search covers every
/// channel the caller can view, not just whichever one is already open;
/// `currentChannelId` is passed through only so a hit in the channel already
/// open jumps in place instead of navigating to itself.
Future<void> openCommandPalette(BuildContext context) async {
  final previousFocus = FocusManager.instance.primaryFocus;
  final channelId = selectedChannelId(context);

  await showGeneralDialog<void>(
    context: context,
    barrierLabel: 'Command palette',
    barrierDismissible: true,
    barrierColor: kScrimColor,
    // The same 180ms AppMotion.base `modalPage` and `showAppSheet` use.
    transitionDuration: AppMotion.reduced(context, AppMotion.base),
    pageBuilder: (context, animation, secondaryAnimation) =>
        _CommandPaletteContent(currentChannelId: channelId),
    // member_profile.dart's authored entrance: a curved fade with an 8px rise.
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.entrance,
        reverseCurve: AppMotion.exit,
      );
      return FadeTransition(
        opacity: curved,
        child: AnimatedBuilder(
          animation: curved,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, (1 - curved.value) * 8),
            child: child,
          ),
          child: child,
        ),
      );
    },
  );

  // The dialog may have outlived whatever held focus before it opened, so only
  // claim it back if it is still attached to something that can take it.
  if (previousFocus != null && previousFocus.context != null) {
    previousFocus.requestFocus();
  }
}

class _CommandPaletteContent extends ConsumerStatefulWidget {
  const _CommandPaletteContent({required this.currentChannelId});

  final String? currentChannelId;

  @override
  ConsumerState<_CommandPaletteContent> createState() =>
      _CommandPaletteContentState();
}

class _CommandPaletteContentState
    extends ConsumerState<_CommandPaletteContent> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  String _query = '';
  int _highlighted = 0;
  List<api.Message> _messageResults = const [];

  /// Whether the last message search came back as a 403 rather than a
  /// genuinely empty result; the two must not read the same.
  bool _messagesForbidden = false;

  /// Guards against a fast typist's earlier request resolving after a later
  /// one and clobbering its results, since there is no debounce here (the
  /// channel search bar this mirrors has none either).
  int _searchGeneration = 0;

  /// The last frame's flat result list, so a key handler (which runs outside
  /// build) can act on exactly what the user is looking at right now.
  List<PaletteResultItem> _visible = const [];

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() {
      _query = value;
      _highlighted = 0;
    });
    if (value.isEmpty) {
      setState(() {
        _messageResults = const [];
        _messagesForbidden = false;
      });
      return;
    }
    _search(value);
  }

  /// The command palette's own cross-channel scope: every channel the caller
  /// can view, through the same shared helper `channelSearchProvider` uses
  /// for its own single-channel search - identical blocked-author filtering,
  /// and the same 403-versus-any-other-failure distinction, so the two
  /// cannot diverge again the way they already had.
  Future<void> _search(String query) async {
    final generation = ++_searchGeneration;
    final result = await searchAllMessages(
      ref.read,
      query,
      limit: paletteResultLimit,
    );
    if (!mounted || generation != _searchGeneration) return;
    setState(() {
      switch (result) {
        case MessageSearchHits(:final messages):
          _messageResults = messages;
          _messagesForbidden = false;
        case MessageSearchForbidden():
          _messageResults = const [];
          _messagesForbidden = true;
        case MessageSearchFailed():
          _messageResults = const [];
          _messagesForbidden = false;
      }
    });
  }

  void _move(int delta) {
    if (_visible.isEmpty) return;
    setState(() {
      _highlighted = (_highlighted + delta) % _visible.length;
      if (_highlighted < 0) _highlighted += _visible.length;
    });
  }

  Future<void> _runHighlighted() async {
    if (_visible.isEmpty) return;
    await _run(_visible[_highlighted]);
  }

  Future<void> _run(PaletteResultItem item) async {
    await item.onSelect(context, ref);
    if (mounted) Navigator.of(context).pop();
  }

  Map<ShortcutActivator, VoidCallback> _bindings() {
    final close = activatorFor(AppAction.escape);
    return {
      const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
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
    final personalSpaceHidden = ref.watch(personalSpaceVisibilityProvider);
    // Re-read every build, so a resize crossing it while open swaps shells live.
    final compact = MediaQuery.sizeOf(context).width < kCompactWidth;

    final searchField = AppInput(
      maxLength: api.InputLimits.searchQuery,
      key: const Key('command-palette-input'),
      controller: _controller,
      focusNode: _focusNode,
      autofocus: true,
      size: compact ? AppInputSize.lg : AppInputSize.md,
      placeholder: 'Search channels, members and messages',
      icon: Icon(
        AppIcons.search,
        size: AppSizes.icon16,
        color: tokens.textSecondary,
      ),
      onChanged: _onQueryChanged,
      onSubmitted: (_) => _runHighlighted(),
      semanticLabel: 'Search channels, members and messages',
    );

    final results = storeAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => const SizedBox.shrink(),
      data: (store) => StreamBuilder<List<Channel>>(
        stream: store.watchChannels(),
        builder: (context, snapshot) {
          final channels = snapshot.data ?? const <Channel>[];
          // Keyed on the query alone: arrow keys and late-arriving message hits update in place, only typing crossfades.
          return MaybeAnimatedSize(
            duration: AppMotion.fast,
            curve: AppMotion.entrance,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: AppMotion.reduced(context, AppMotion.fast),
              switchInCurve: AppMotion.entrance,
              switchOutCurve: AppMotion.exit,
              child: KeyedSubtree(
                key: ValueKey(_query),
                child: _buildResults(
                  tokens,
                  channels,
                  members,
                  me,
                  permissions,
                  personalSpaceHidden,
                ),
              ),
            ),
          );
        },
      ),
    );

    final shell = compact
        ? CommandPaletteCompactShell(
            searchField: searchField,
            results: results,
            onCancel: () => Navigator.of(context).pop(),
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
                    child: searchField,
                  ),
                  const AppMenuDivider(),
                  results,
                  const AppMenuDivider(),
                  _paletteKbdFooter(tokens),
                ],
              ),
            ),
          );

    return CallbackShortcuts(bindings: _bindings(), child: shell);
  }

  Widget _buildResults(
    AppTokens tokens,
    List<Channel> channels,
    List<api.UserProfile> members,
    api.Me? me,
    int permissions,
    bool personalSpaceHidden,
  ) {
    resolveAuthorProfiles(ref, _messageResults.map((m) => m.authorId));
    final groups = <(String, List<PaletteResultItem>)>[
      (
        'Channels',
        buildChannelItems(
          channels,
          _query,
          selfDisplayName: me?.displayName,
          personalSpaceHidden: personalSpaceHidden,
        ),
      ),
      ('Members', buildMemberItems(members, _query, me?.id)),
      if (!_messagesForbidden)
        (
          'Messages',
          buildMessageItems(
            _messageResults,
            currentChannelId: widget.currentChannelId,
          ),
        ),
      ('Actions', buildActionItems(_query, permissions)),
    ].where((g) => g.$2.isNotEmpty).toList();

    // An empty result and a refusal are different things; so says search too.
    final showForbiddenNotice = _messagesForbidden && _query.isNotEmpty;

    final flat = [for (final group in groups) ...group.$2];
    _visible = flat;
    if (_highlighted >= flat.length) {
      _highlighted = flat.isEmpty ? 0 : flat.length - 1;
    }

    if (flat.isEmpty && !showForbiddenNotice) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.s16),
        child: Text(
          'No matches.',
          style: AppText.body.copyWith(color: tokens.textSecondary),
        ),
      );
    }

    final rows = <Widget>[];
    var index = 0;
    for (final group in groups) {
      rows.add(AppMenuLabel(group.$1));
      for (final item in group.$2) {
        final at = index;
        index++;
        rows.add(
          AppMenuItem(
            label: item.label,
            leading: item.leading,
            trailing: item.trailing,
            selected: at == _highlighted,
            semanticLabel: item.semanticLabel,
            onTap: () => _run(item),
          ),
        );
      }
    }
    if (showForbiddenNotice) {
      rows.add(const AppMenuLabel('Messages'));
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s16,
            vertical: AppSpacing.s8,
          ),
          child: Text(
            'You do not have permission to search this channel.',
            style: AppText.micro.copyWith(color: tokens.textSecondary),
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: _resultsMaxHeight),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: rows),
      ),
    );
  }
}

/// The floating card's own footer: arrow/Enter hints and a nudge that typing
/// narrows the list. Desktop-only - `CommandPaletteCompactShell` never builds
/// this, matching `channel_rail.dart`'s own "keycaps only where a keyboard
/// is" rule for the Ctrl+K hint beside it.
Widget _paletteKbdFooter(AppTokens tokens) {
  Widget hint(List<String> keys, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: AppSpacing.s4,
    children: [
      for (final key in keys) AppKbd(key),
      Text(label, style: AppText.micro.copyWith(color: tokens.textSecondary)),
    ],
  );

  return Padding(
    padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
    child: Wrap(
      spacing: AppSpacing.s16,
      runSpacing: AppSpacing.s4,
      children: [
        hint(const ['↑', '↓'], 'to navigate'),
        hint(const ['Enter'], 'to select'),
        Text(
          'Type to filter',
          style: AppText.micro.copyWith(color: tokens.textSecondary),
        ),
      ],
    ),
  );
}
