// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Turns the runtime's multiplexed log stream into `{"ts", "stream", "text"}` lines.

use serde::Serialize;

pub const MAX_LINES: usize = 1000;
pub const MAX_BYTES: usize = 256 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Line {
    pub ts: String,
    pub stream: &'static str,
    pub text: String,
}

/// Each frame is an 8-byte header (stream, three zero bytes, big-endian length) and its
/// payload; with `timestamps=1` every line starts with an RFC 3339 time and a space.
/// The newest lines are kept when the caps cut.
pub fn demux(raw: &[u8]) -> Vec<Line> {
    let mut lines = Vec::new();
    let mut rest = raw;
    while rest.len() >= 8 {
        let stream = match rest[0] {
            2 => "stderr",
            _ => "stdout",
        };
        let len = u32::from_be_bytes([rest[4], rest[5], rest[6], rest[7]]) as usize;
        let end = (8 + len).min(rest.len());
        let payload = String::from_utf8_lossy(&rest[8..end]);
        for line in payload.split_terminator('\n') {
            let (ts, text) = line.split_once(' ').unwrap_or(("", line));
            lines.push(Line {
                ts: ts.to_owned(),
                stream,
                text: printable(text.trim_end_matches('\r')),
            });
        }
        rest = &rest[end..];
    }
    cap(lines)
}

/// Control characters other than tab become U+FFFD so JSON escaping cannot outgrow the byte cap.
fn printable(text: &str) -> String {
    text.chars()
        .map(|c| {
            if c.is_control() && c != '\t' {
                '\u{FFFD}'
            } else {
                c
            }
        })
        .collect()
}

fn cap(mut lines: Vec<Line>) -> Vec<Line> {
    if lines.len() > MAX_LINES {
        lines.drain(..lines.len() - MAX_LINES);
    }
    let mut total = 0;
    let mut keep = lines.len();
    for (i, line) in lines.iter().enumerate().rev() {
        total += line.text.len() + line.ts.len();
        if total > MAX_BYTES {
            break;
        }
        keep = i;
    }
    lines.split_off(keep)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(stream: u8, text: &str) -> Vec<u8> {
        let mut out = vec![stream, 0, 0, 0];
        out.extend_from_slice(&(text.len() as u32).to_be_bytes());
        out.extend_from_slice(text.as_bytes());
        out
    }

    #[test]
    fn frames_become_lines_with_their_stream() {
        let mut raw = frame(1, "2026-11-22T10:00:00Z hello\n2026-11-22T10:00:01Z two\n");
        raw.extend(frame(2, "2026-11-22T10:00:02Z oops\n"));
        let lines = demux(&raw);
        assert_eq!(lines.len(), 3);
        assert_eq!(
            lines[0],
            Line {
                ts: "2026-11-22T10:00:00Z".into(),
                stream: "stdout",
                text: "hello".into()
            }
        );
        assert_eq!(lines[2].stream, "stderr");
    }

    #[test]
    fn the_newest_lines_survive_the_caps() {
        let text: String = (0..1500)
            .map(|i| format!("2026-11-22T10:00:00Z line{i}\n"))
            .collect();
        let lines = demux(&frame(1, &text));
        assert_eq!(lines.len(), MAX_LINES);
        assert_eq!(lines.last().unwrap().text, "line1499");
        let big = "x".repeat(200 * 1024);
        let mut raw = frame(1, &format!("t {big}\n"));
        raw.extend(frame(1, &format!("t {big}\n")));
        let lines = demux(&raw);
        assert_eq!(lines.len(), 1);
    }

    #[test]
    fn control_characters_cannot_push_the_log_past_its_cap() {
        let noisy = "\u{1}".repeat(50 * 1024);
        let lines = demux(&frame(1, &format!("t {noisy}\nt ok\n")));
        assert_eq!(lines.last().unwrap().text, "ok");
        let serialized = serde_json::to_string(&lines).unwrap();
        assert!(serialized.len() < MAX_BYTES, "{}", serialized.len());
        assert!(lines[0].text.starts_with('\u{FFFD}'));
    }

    #[test]
    fn a_truncated_frame_does_not_panic() {
        let mut raw = frame(1, "t hello\n");
        raw.truncate(10);
        assert_eq!(demux(&raw).len(), 1);
    }
}
