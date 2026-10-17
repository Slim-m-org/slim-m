// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Parsing the moderation-history pagination cursor, split out of `reports.rs`
//! so it has a home to be unit-tested in and the handler file stays under its
//! line budget. A pure function of its three string arguments.

use super::super::error::ApiError;
use super::super::messages::parse_uuid;
use crate::store::HistoryCursor;

/// Parses a history cursor's `after_kind`/`after_id` pair against the
/// `after` event time. `after_kind` says which id shape `after_id` must be:
/// a UUID for a resolved report, a plain integer for an audit row's rowid.
pub(in crate::http) fn parse_history_cursor(
    event_time: i64,
    kind: &str,
    id: &str,
) -> Result<HistoryCursor, ApiError> {
    match kind {
        "resolved_report" => Ok(HistoryCursor::Report {
            resolved_at: event_time,
            id: parse_uuid(id)?,
        }),
        "audit_log" => {
            let id: i64 = id.parse().map_err(|_| {
                ApiError::BadRequest("after_id must be an integer for an audit_log cursor")
            })?;
            Ok(HistoryCursor::Audit {
                created_at: event_time,
                id,
            })
        }
        _ => Err(ApiError::BadRequest(
            "after_kind must be resolved_report or audit_log",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::parse_history_cursor;
    use crate::store::HistoryCursor;

    #[test]
    fn a_resolved_report_cursor_takes_its_id_as_a_uuid() {
        let ok = parse_history_cursor(7, "resolved_report", "00000000-0000-0000-0000-00000000000a");
        assert!(matches!(
            ok,
            Ok(HistoryCursor::Report { resolved_at: 7, .. })
        ));
        assert!(parse_history_cursor(7, "resolved_report", "not-a-uuid").is_err());
    }

    /// The audit id is a plain rowid, so it must parse as an integer, not the
    /// UUID the report branch takes - the two id shapes are what `after_kind`
    /// disambiguates.
    #[test]
    fn an_audit_cursor_takes_its_id_as_an_integer() {
        let ok = parse_history_cursor(9, "audit_log", "42");
        assert!(matches!(
            ok,
            Ok(HistoryCursor::Audit {
                created_at: 9,
                id: 42
            })
        ));
        assert!(parse_history_cursor(9, "audit_log", "3f").is_err());
    }

    #[test]
    fn an_unknown_kind_is_refused() {
        assert!(parse_history_cursor(0, "nonsense", "1").is_err());
    }
}
