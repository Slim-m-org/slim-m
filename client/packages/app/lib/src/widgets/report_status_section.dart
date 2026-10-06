// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Lets a reporter see their own filed reports, and check on one by id.
///
/// Before `GET /reports/mine/{reportId}` existed, every report-reading
/// surface sat behind deployment-wide MANAGE_MESSAGES, so filing a report
/// was fire-and-forget: nothing told the person who filed it whether it had
/// reached anyone. This is the client side of that narrow, status-only read
/// - not a queue, not a history, just "is a report I filed still open".
///
/// [_FiledReportRow] is the primary surface now: `fileReport` remembers each
/// new report's id in [filedReportsProvider], so every report filed from
/// this device already appears below with no id ever shown to, or typed by,
/// the reporter. The manual id field stays as a fallback for a report filed
/// on a different device, or before this list existed.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../api_failure.dart';
import '../format.dart';
import '../providers/filed_reports.dart';
import '../providers/providers.dart';
import 'settings_section_header.dart';

class ReportStatusSection extends ConsumerWidget {
  const ReportStatusSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final filedIds = ref.watch(filedReportsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionCard(
          title: 'Reports you filed',
          description:
              'Reports from this device, and whether each is still open.',
          children: [
            if (filedIds.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.s8),
                child: Text(
                  'Nothing filed from this device yet.',
                  style: AppText.body.copyWith(color: tokens.textSecondary),
                ),
              )
            else
              for (final id in filedIds)
                _FiledReportRow(key: ValueKey(id), reportId: id),
          ],
        ),
        const SizedBox(height: AppSpacing.s16),
        const _CheckByIdSection(),
      ],
    );
  }
}

/// One remembered report id, fetched and shown as soon as it mounts rather
/// than on a manual trigger - the whole point is that the reporter never
/// has to ask for this by id themselves.
class _FiledReportRow extends ConsumerStatefulWidget {
  const _FiledReportRow({super.key, required this.reportId});

  final String reportId;

  @override
  ConsumerState<_FiledReportRow> createState() => _FiledReportRowState();
}

class _FiledReportRowState extends ConsumerState<_FiledReportRow> {
  api.MyReportStatus? _status;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final status = await ref
          .read(apiProvider)
          .myReportStatus(widget.reportId);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = status;
      });
    } on api.NotFoundException {
      // The reporter's account was anonymized, or this id was never theirs.
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No longer available.';
      });
    } on api.ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = describeApiFailure('check that report', e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.s8),
        child: LinearProgressIndicator(),
      );
    }
    if (_error case final error?) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.s8),
        child: Text(
          error,
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      );
    }
    final status = _status!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s8),
      child: Text(
        status.resolved
            ? 'Resolved. Filed ${_filedAgo(status.createdAt)}.'
            : 'Still open. Filed ${_filedAgo(status.createdAt)}.',
        style: AppText.body.copyWith(color: tokens.textPrimary),
      ),
    );
  }
}

/// The manual "paste an id" fallback: `_ReportStatusSectionState`'s
/// original whole surface, kept for a report [filedReportsProvider] does
/// not know about.
class _CheckByIdSection extends ConsumerStatefulWidget {
  const _CheckByIdSection();

  @override
  ConsumerState<_CheckByIdSection> createState() => _CheckByIdSectionState();
}

class _CheckByIdSectionState extends ConsumerState<_CheckByIdSection> {
  final _idController = TextEditingController();
  api.MyReportStatus? _result;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _idController.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final reportId = _idController.text.trim();
    if (reportId.isEmpty) return;
    setState(() {
      _busy = true;
      _result = null;
      _error = null;
    });
    try {
      final status = await ref.read(apiProvider).myReportStatus(reportId);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _result = status;
      });
    } on api.NotFoundException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // Same wording either way; the server route refuses to tell those apart.
        _error = 'No report found with that ID.';
      });
    } on api.ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeApiFailure('check that report', e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SettingsSectionCard(
      title: 'Check a report by ID',
      description: 'Paste the ID of a report from another device.',
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: AppInput(
                controller: _idController,
                placeholder: 'Report ID',
                mono: true,
                size: AppInputSize.sm,
                onSubmitted: (_) => _check(),
              ),
            ),
            const SizedBox(width: AppSpacing.s8),
            AppButton(
              label: 'Check',
              size: AppButtonSize.sm,
              disabled: _busy,
              onPressed: _check,
            ),
          ],
        ),
        if (_result case final status?)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s12),
            child: Text(
              status.resolved
                  ? 'Resolved. Filed ${_filedAgo(status.createdAt)}.'
                  : 'Still open. Filed ${_filedAgo(status.createdAt)}.',
              style: AppText.body.copyWith(color: tokens.textPrimary),
            ),
          ),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s12),
            child: AppErrorState(
              message: error,
              onDismiss: () => setState(() => _error = null),
            ),
          ),
      ],
    );
  }
}

/// A short, relative "filed X ago" for [createdAtMs] (Unix milliseconds).
/// Counts in weeks: a filed report is realistic to check back on well after
/// a day has passed.
String _filedAgo(int createdAtMs) =>
    formatRelativeAgeMs(createdAtMs, weeks: true);
