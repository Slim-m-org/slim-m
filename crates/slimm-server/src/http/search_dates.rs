// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The calendar dates `before:`/`after:` name, as epoch milliseconds at their
//! UTC midnight, split out of `http::search` to keep that file in budget.

use super::error::ApiError;

/// Parses a `YYYY-MM-DD` calendar date into the epoch millisecond at its
/// midnight UTC start, so `before:`/`after:` compare against `created_at`
/// with no timezone to resolve. Byte-indexed rather than `str`-sliced: a
/// length check alone does not rule out a multi-byte character landing where
/// a slice boundary would fall, which `&s[0..4]`-style slicing can panic on.
pub(super) fn parse_date_start(s: &str) -> Result<i64, ApiError> {
    const BAD: ApiError = ApiError::BadRequest("date must be YYYY-MM-DD");
    let bytes = s.as_bytes();
    if bytes.len() != 10 || bytes[4] != b'-' || bytes[7] != b'-' {
        return Err(BAD);
    }
    let digit = |b: u8| -> Result<i64, ApiError> {
        if b.is_ascii_digit() {
            Ok((b - b'0') as i64)
        } else {
            Err(BAD)
        }
    };
    let year =
        digit(bytes[0])? * 1000 + digit(bytes[1])? * 100 + digit(bytes[2])? * 10 + digit(bytes[3])?;
    let month = (digit(bytes[5])? * 10 + digit(bytes[6])?) as u32;
    let day = (digit(bytes[8])? * 10 + digit(bytes[9])?) as u32;
    if !(1..=12).contains(&month) {
        return Err(BAD);
    }
    let dim = days_in_month(year, month);
    if day < 1 || day > dim {
        return Err(BAD);
    }
    Ok(days_from_civil(year, month, day) * 86_400_000)
}

fn is_leap_year(y: i64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

fn days_in_month(y: i64, m: u32) -> u32 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            if is_leap_year(y) {
                29
            } else {
                28
            }
        }
        _ => 0,
    }
}

/// Howard Hinnant's `days_from_civil`: the standard, well-tested closed-form
/// conversion from a proleptic Gregorian calendar date to a day count
/// relative to the Unix epoch (1970-01-01 = 0). Chosen over the `jiff`
/// dependency already in this workspace because nothing else here uses it
/// yet, and a closed-form arithmetic conversion this small is easier to
/// trust by reading than by taking on an unfamiliar API for one call site.
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m as i64 + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `ApiError` has no `Debug`, so a bare `.unwrap()` on it will not compile.
    fn ok<T>(r: Result<T, ApiError>) -> T {
        match r {
            Ok(v) => v,
            Err(_) => panic!("expected Ok"),
        }
    }

    #[test]
    fn epoch_day_is_zero() {
        assert_eq!(ok(parse_date_start("1970-01-01")), 0);
    }

    #[test]
    fn a_known_date_matches_a_reference_conversion() {
        assert_eq!(ok(parse_date_start("2024-01-01")), 1_704_067_200_000);
        assert_eq!(ok(parse_date_start("2024-02-29")), 1_709_164_800_000);
        assert_eq!(ok(parse_date_start("2000-03-01")), 951_868_800_000);
        assert_eq!(ok(parse_date_start("1999-12-31")), 946_598_400_000);
    }

    #[test]
    fn a_non_leap_year_february_stops_at_28() {
        assert!(parse_date_start("2023-02-29").is_err());
        assert!(parse_date_start("2023-02-28").is_ok());
    }

    #[test]
    fn month_and_day_are_range_checked() {
        assert!(parse_date_start("2024-13-01").is_err());
        assert!(parse_date_start("2024-00-01").is_err());
        assert!(parse_date_start("2024-04-31").is_err());
        assert!(parse_date_start("2024-04-00").is_err());
    }

    #[test]
    fn malformed_shapes_are_rejected_rather_than_panicking() {
        assert!(parse_date_start("2024/01/01").is_err());
        assert!(parse_date_start("2024-1-1").is_err());
        assert!(parse_date_start("not-a-date").is_err());
        assert!(parse_date_start("").is_err());
        // A 2-byte `é` keeping the total byte length at 10 must not panic on slicing.
        assert!(parse_date_start("20é-01-01").is_err());
    }
}
