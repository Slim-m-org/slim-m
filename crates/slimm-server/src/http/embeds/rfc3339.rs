// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A small RFC 3339 reader for the webhook route's embed `timestamp`, which
//! Discord-shaped senders write as an ISO 8601 string.

/// The first year a parsed timestamp may carry; an earlier one is a sender's "unset" placeholder.
const MIN_YEAR: i64 = 1970;

/// Epoch milliseconds for an RFC 3339 date-time, or `None` for anything else.
///
/// Takes `Z`/`z` or a `+HH:MM`/`-HH:MM` offset, any number of fractional
/// digits (truncated to milliseconds), and years 1970 through 9999.
pub(super) fn parse_ms(text: &str) -> Option<i64> {
    let b = text.as_bytes();
    if b.len() < 20 || !matches!(b[10], b'T' | b't') || b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    if b[13] != b':' || b[16] != b':' {
        return None;
    }
    let year = digits(&b[0..4])?;
    let month = digits(&b[5..7])?;
    let day = digits(&b[8..10])?;
    let hour = digits(&b[11..13])?;
    let minute = digits(&b[14..16])?;
    let second = digits(&b[17..19])?;
    if year < MIN_YEAR || !(1..=12).contains(&month) {
        return None;
    }
    if day < 1 || day > days_in_month(year, month) {
        return None;
    }
    if hour > 23 || minute > 59 || second > 60 {
        return None;
    }

    let (millis, rest) = fraction(&b[19..])?;
    let offset_minutes = offset(rest)?;
    let seconds = days_from_civil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second;
    Some((seconds - offset_minutes * 60) * 1_000 + millis)
}

/// The fractional seconds as whole milliseconds, and the bytes after them.
fn fraction(b: &[u8]) -> Option<(i64, &[u8])> {
    if b.first() != Some(&b'.') {
        return Some((0, b));
    }
    let len = b[1..].iter().take_while(|c| c.is_ascii_digit()).count();
    if len == 0 {
        return None;
    }
    let kept = &b[1..1 + len.min(3)];
    let scale = 10_i64.pow(3 - kept.len() as u32);
    Some((digits(kept)? * scale, &b[1 + len..]))
}

/// A UTC offset in minutes from the trailing `Z` or `+HH:MM`.
fn offset(b: &[u8]) -> Option<i64> {
    match b {
        [b'Z' | b'z'] => Some(0),
        [sign @ (b'+' | b'-'), h1, h2, b':', m1, m2] => {
            let hours = digits(&[*h1, *h2])?;
            let minutes = digits(&[*m1, *m2])?;
            if hours > 23 || minutes > 59 {
                return None;
            }
            let total = hours * 60 + minutes;
            Some(if *sign == b'-' { -total } else { total })
        }
        _ => None,
    }
}

fn digits(b: &[u8]) -> Option<i64> {
    b.iter().try_fold(0_i64, |acc, c| {
        c.is_ascii_digit().then(|| acc * 10 + i64::from(c - b'0'))
    })
}

fn is_leap(year: i64) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        2 if is_leap(year) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// Days since 1970-01-01 for a valid proleptic Gregorian date (Hinnant's civil-days algorithm).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let year_of_era = y - era * 400;
    let shifted_month = if month > 2 { month - 3 } else { month + 9 };
    let day_of_year = (153 * shifted_month + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

#[cfg(test)]
mod tests {
    use super::parse_ms;

    #[test]
    fn the_epoch_is_zero() {
        assert_eq!(parse_ms("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_ms("1970-01-01t00:00:00z"), Some(0));
    }

    #[test]
    fn a_discord_style_utc_string_is_exact() {
        assert_eq!(
            parse_ms("2026-10-04T12:00:00.000Z"),
            Some(1_791_115_200_000)
        );
        assert_eq!(parse_ms("2026-10-04T12:00:00Z"), Some(1_791_115_200_000));
    }

    #[test]
    fn fractional_digits_of_any_length_truncate_to_milliseconds() {
        let base = 1_791_115_200_000;
        assert_eq!(parse_ms("2026-10-04T12:00:00.5Z"), Some(base + 500));
        assert_eq!(parse_ms("2026-10-04T12:00:00.12Z"), Some(base + 120));
        assert_eq!(parse_ms("2026-10-04T12:00:00.123Z"), Some(base + 123));
        assert_eq!(parse_ms("2026-10-04T12:00:00.1239Z"), Some(base + 123));
        assert_eq!(parse_ms("2026-10-04T12:00:00.1234567Z"), Some(base + 123));
        assert_eq!(parse_ms("2026-10-04T12:00:00.9999999Z"), Some(base + 999));
    }

    #[test]
    fn a_fraction_with_no_digits_is_refused() {
        assert_eq!(parse_ms("2026-10-04T12:00:00.Z"), None);
    }

    #[test]
    fn an_offset_is_subtracted_to_reach_utc() {
        let noon = 1_791_115_200_000;
        assert_eq!(parse_ms("2026-10-04T14:00:00+02:00"), Some(noon));
        assert_eq!(parse_ms("2026-10-04T07:00:00-05:00"), Some(noon));
        assert_eq!(parse_ms("2026-10-04T17:30:00+05:30"), Some(noon));
        assert_eq!(parse_ms("2026-10-04T12:00:00-00:00"), Some(noon));
        assert_eq!(parse_ms("2026-10-04T14:00:00.250+02:00"), Some(noon + 250));
    }

    #[test]
    fn an_offset_that_crosses_midnight_changes_the_utc_date() {
        let expect = parse_ms("2026-10-04T23:30:00Z");
        assert_eq!(parse_ms("2026-10-05T01:30:00+02:00"), expect);
        assert_eq!(parse_ms("2026-10-04T18:30:00-05:00"), expect);
        assert_eq!(
            parse_ms("2026-01-01T00:30:00+01:00"),
            parse_ms("2025-12-31T23:30:00Z")
        );
    }

    #[test]
    fn leap_days_exist_only_in_leap_years() {
        assert!(parse_ms("2028-02-29T00:00:00Z").is_some());
        assert!(parse_ms("2000-02-29T00:00:00Z").is_some());
        assert_eq!(parse_ms("2026-02-29T00:00:00Z"), None);
        assert_eq!(parse_ms("2100-02-29T00:00:00Z"), None);
    }

    #[test]
    fn leap_day_arithmetic_is_exact() {
        assert_eq!(parse_ms("2028-02-29T00:00:00Z"), Some(1_835_395_200_000));
        assert_eq!(
            parse_ms("2028-03-01T00:00:00Z").unwrap() - parse_ms("2028-02-29T00:00:00Z").unwrap(),
            86_400_000
        );
    }

    #[test]
    fn month_ends_are_enforced() {
        assert!(parse_ms("2026-04-30T00:00:00Z").is_some());
        assert_eq!(parse_ms("2026-04-31T00:00:00Z"), None);
        assert!(parse_ms("2026-12-31T23:59:59Z").is_some());
        assert_eq!(parse_ms("2026-13-01T00:00:00Z"), None);
        assert_eq!(parse_ms("2026-00-10T00:00:00Z"), None);
        assert_eq!(parse_ms("2026-01-00T00:00:00Z"), None);
        assert_eq!(
            parse_ms("2026-12-31T23:59:59Z").unwrap() + 1_000,
            parse_ms("2027-01-01T00:00:00Z").unwrap()
        );
    }

    #[test]
    fn a_time_out_of_range_is_refused() {
        assert_eq!(parse_ms("2026-10-04T24:00:00Z"), None);
        assert_eq!(parse_ms("2026-10-04T12:60:00Z"), None);
        assert_eq!(parse_ms("2026-10-04T12:00:61Z"), None);
        assert_eq!(parse_ms("2026-10-04T12:00:00+24:00"), None);
        assert_eq!(parse_ms("2026-10-04T12:00:00+02:60"), None);
    }

    #[test]
    fn a_leap_second_rolls_into_the_next_minute() {
        assert_eq!(
            parse_ms("2016-12-31T23:59:60Z"),
            parse_ms("2017-01-01T00:00:00Z")
        );
    }

    #[test]
    fn a_year_outside_1970_through_9999_is_refused() {
        assert_eq!(parse_ms("1969-12-31T23:59:59Z"), None);
        assert_eq!(parse_ms("0001-01-01T00:00:00Z"), None);
        assert_eq!(parse_ms("0000-01-01T00:00:00Z"), None);
        assert_eq!(parse_ms("10000-01-01T00:00:00Z"), None);
        assert!(parse_ms("9999-12-31T23:59:59Z").is_some());
    }

    #[test]
    fn garbage_is_refused() {
        for text in [
            "",
            "not a date",
            "2026-10-04",
            "2026-10-04T12:00:00",
            "2026-10-04 12:00:00Z",
            "2026-10-04T12:00Z",
            "2026-10-04T12:00:00+0200",
            "2026-10-04T12:00:00+02",
            "2026-10-04T12:00:00ZZ",
            "2026-10-04T12:00:00Z ",
            "2026/10/04T12:00:00Z",
            "2026-10-04T12-00-00Z",
            "2026-1a-04T12:00:00Z",
            "+026-10-04T12:00:00Z",
            "2026-10-04T12:00:00+0\u{e9}:00",
            "2026-10-04T12:00:00.\u{e9}Z",
            "\u{e9}026-10-04T12:00:00Z",
            "1791115200000",
        ] {
            assert_eq!(parse_ms(text), None, "{text:?}");
        }
    }
}
