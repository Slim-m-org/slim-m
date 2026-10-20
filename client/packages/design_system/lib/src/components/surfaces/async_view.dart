// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One treatment for the three states every fetched surface has.
///
/// A component-usage audit found five different shapes for the same job
/// across eighteen `AsyncValue.when` sites: a bare centred spinner, a spinner
/// with a caption, a left-aligned message, a centred message, and one screen
/// with no empty state at all rendering a blank page. Each was defensible
/// alone and the set read as unfinished, which is the failure mode a shared
/// component exists to prevent.
///
/// Error copy goes through [AppErrorState], so a failed fetch obeys the same
/// grammar as a failed action: it persists, it says what happened in plain
/// words, and it offers a way forward.
library;

import 'package:flutter/material.dart';

import '../../app_fade_in.dart';
import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';
import '../core/spinner.dart';
import 'error_state.dart';

/// Renders [loading], [error] or [data] for an async value, with one look.
///
/// [empty] is separate from [data] on purpose: "nothing here yet" and "here
/// is the list" are different messages, and collapsing them is how a screen
/// ends up rendering a blank page. Give [emptyMessage] and an [isEmpty] test
/// to get it; without them an empty list simply reaches [data].
///
/// A refresh that fails after a successful fetch keeps its last known value
/// (Riverpod's own retained-previous-data behaviour), so a caller building
/// [value] straight off an `AsyncValue` can carry a real error and real data
/// at once. This renders that data with the error banner above it rather
/// than wiping a perfectly good list for no better reason than a retry not
/// having landed yet, and it does that inside both the shapes a caller
/// embeds this in: a bounded box (an `Expanded` ancestor, so [data] can be a
/// `ListView` that needs one) and an unbounded one (the default scrollable
/// settings frame, where [data] is already written to size itself instead).
class AppAsyncView<T> extends StatelessWidget {
  const AppAsyncView({
    super.key,
    required this.value,
    required this.data,
    required this.errorMessage,
    this.onRetry,
    this.loadingMessage,
    this.isEmpty,
    this.emptyMessage,
    this.center = true,
  });

  /// The fetch, as an [AppAsyncState]. Typed loosely so this package does not
  /// depend on Riverpod: build one at the call site from an `AsyncValue` as
  /// `AppAsyncState(data: async.valueOrNull, error: async.error)` - a null
  /// [AppAsyncState.data] with no error renders the loading state.
  final AppAsyncState<T> value;

  final Widget Function(BuildContext context, T data) data;

  /// Plain words, never an exception. What failed and what it means.
  final String errorMessage;

  final VoidCallback? onRetry;

  /// Shown beneath the spinner. A bare spinner is fine for a fast fetch; a
  /// caption is worth it where the wait has a reason worth naming.
  final String? loadingMessage;

  final bool Function(T data)? isEmpty;
  final String? emptyMessage;

  /// Centres each state in the space it is given. False left-aligns them,
  /// for a surface that sits inline in a column rather than owning a pane.
  final bool center;

  Widget _wrap(Widget child) => center
      ? Center(child: child)
      : Align(alignment: Alignment.centerLeft, child: child);

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    if (value.error != null) return _errored();

    final resolved = value.data;
    if (resolved == null) return _loading(tokens);

    if (emptyMessage != null && (isEmpty?.call(resolved) ?? false)) {
      return _empty(tokens);
    }

    // A resolve settles in once on mount; later data rebuilds swap in place.
    return AppFadeIn(child: data(context, resolved));
  }

  Widget _errored() {
    // Kept and shown below rather than discarded; see this class's own doc.
    final stale = value.data;
    if (stale == null) {
      return _wrap(
        Padding(
          padding: const EdgeInsets.all(AppSpacing.s16),
          child: AppErrorState(message: errorMessage, onRetry: onRetry),
        ),
      );
    }
    final banner = Padding(
      padding: const EdgeInsets.all(AppSpacing.s12),
      child: AppErrorState(message: errorMessage, onRetry: onRetry),
    );
    // Which layout is safe follows the constraint actually given here.
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize:
            constraints.hasBoundedHeight ? MainAxisSize.max : MainAxisSize.min,
        children: [
          banner,
          constraints.hasBoundedHeight
              ? Expanded(child: data(context, stale))
              : data(context, stale),
        ],
      ),
    );
  }

  Widget _loading(AppTokens tokens) {
    return _wrap(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppSpinner(size: AppSpinnerSize.md),
          if (loadingMessage != null) ...[
            const SizedBox(height: AppSpacing.s12),
            Text(
              loadingMessage!,
              style: AppText.body.copyWith(color: tokens.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _empty(AppTokens tokens) {
    return AppFadeIn(
      child: _wrap(
        Padding(
          padding: const EdgeInsets.all(AppSpacing.s16),
          child: Text(
            emptyMessage!,
            textAlign: center ? TextAlign.center : TextAlign.start,
            style: AppText.body.copyWith(color: tokens.textSecondary),
          ),
        ),
      ),
    );
  }
}

/// The three-state shape [AppAsyncView] reads, so the design system stays
/// free of a Riverpod dependency. Build one from an `AsyncValue` at the call
/// site: `AppAsyncState(data: v.valueOrNull, error: v.error)`.
class AppAsyncState<T> {
  const AppAsyncState({this.data, this.error});

  final T? data;
  final Object? error;
}
