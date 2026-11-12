// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Judging one answer against the operation the schema documents for it.
//!
//! Deliberately a free function over borrowed inputs rather than a method on
//! the fixture: everything the schema says about this answer is read out
//! first, and the verdict is produced from that alone, so nothing here can
//! reach back into the server state it is judging.

use axum::http::StatusCode;
use serde_json::Value;

use super::openapi::Api;

pub struct Answer<'a> {
    pub op: &'a str,
    pub method: &'a str,
    pub uri: &'a str,
    pub status: StatusCode,
    pub media_type: Option<String>,
    pub bytes: &'a [u8],
    /// The caller drove this operation expecting a refusal, so a non-2xx is
    /// the point rather than a failed setup.
    ///
    /// Everything below the success guard already validates against whatever
    /// status the schema documents; only that guard stood between it and the
    /// documented error surface, which is large - 401 on 158 operations, 403
    /// on 103, 400 on 87 - and was checked by nothing.
    pub expect_error: bool,
}

/// Returns the decoded body (so a case can pull ids out of it) and every way
/// the answer failed to match what the schema documents.
///
/// Panics rather than reports when the *case* is wrong - unknown operationId,
/// wrong method, wrong path - since that is a bug in the script, not drift in
/// the server, and quietly recording it as drift would be a lie.
pub fn judge(api: &Api, answer: Answer<'_>) -> (Value, Vec<String>) {
    let Answer {
        op,
        method,
        uri,
        status,
        media_type,
        bytes,
        expect_error,
    } = answer;
    let operation = api
        .operations
        .get(op)
        .unwrap_or_else(|| panic!("schema/openapi.yaml documents no operationId `{op}`"));
    assert_eq!(
        operation.method, method,
        "{op} is documented as {} but this case sends {method}",
        operation.method
    );
    assert!(
        path_matches(&operation.path, uri),
        "{op} is documented at {} but this case calls {uri}",
        operation.path
    );

    let at = format!("{} {} -> {}", operation.method, operation.path, status);
    let body = String::from_utf8_lossy(bytes).into_owned();
    if !status.is_success() && !expect_error {
        return (
            Value::Null,
            vec![format!(
                "{at}: never reached a success status, so its response body was never \
                 checked against the schema. Body: {body}"
            )],
        );
    }
    // Reported, not panicked: a refusal that succeeds is server drift.
    if status.is_success() && expect_error {
        return (
            Value::Null,
            vec![format!(
                "{at}: driven as a refusal case but the server allowed it. Either the \
                 guard it was exercising is gone, or the case no longer sets it up. \
                 Body: {body}"
            )],
        );
    }
    let Some(declared) = operation.responses.get(status.as_str()) else {
        let documented: Vec<&String> = operation.responses.keys().collect();
        return (
            Value::Null,
            vec![format!(
                "{at}: the server answered a status the schema does not document for this \
                 operation (it documents {documented:?})"
            )],
        );
    };
    if declared.is_empty() {
        let problems = if bytes.is_empty() {
            Vec::new()
        } else {
            vec![format!(
                "{at}: the schema documents no response body, the server sent {body}"
            )]
        };
        return (Value::Null, problems);
    }
    let Some(media_type) = media_type else {
        return (
            Value::Null,
            vec![format!("{at}: the response carried no Content-Type")],
        );
    };
    let Some(schema) = declared.get(&media_type) else {
        let documented: Vec<&String> = declared.keys().collect();
        return (
            Value::Null,
            vec![format!(
                "{at}: the server answered Content-Type `{media_type}`, which this response \
                 does not document (it documents {documented:?})"
            )],
        );
    };
    let Some(schema) = schema else {
        return (Value::Null, Vec::new());
    };

    let instance = if media_type == "application/json" {
        match serde_json::from_slice::<Value>(bytes) {
            Ok(value) => value,
            Err(error) => {
                return (
                    Value::Null,
                    vec![format!("{at}: body is not valid JSON ({error}): {body}")],
                );
            }
        }
    } else if media_type.starts_with("text/") {
        Value::String(body)
    } else {
        // A binary body has nothing a JSON Schema can say about it beyond the
        // media type already checked above.
        return (Value::Null, Vec::new());
    };

    let mut problems: Vec<String> = api
        .validator(schema)
        .iter_errors(&instance)
        .map(|error| {
            let path = error.instance_path().as_str().to_owned();
            let path = if path.is_empty() {
                "(root)".to_owned()
            } else {
                path
            };
            format!("{at}: at {path}: {error}")
        })
        .collect();
    problems.extend(api.undocumented(schema, &instance).into_iter().map(|path| {
        format!(
            "{at}: at {path}: the server sends a field schema/openapi.yaml documents \
             nowhere for this response"
        )
    }));
    (instance, problems)
}

fn path_matches(template: &str, uri: &str) -> bool {
    let concrete = uri.split('?').next().unwrap_or(uri);
    let template: Vec<&str> = template.split('/').collect();
    let concrete: Vec<&str> = concrete.split('/').collect();
    template.len() == concrete.len()
        && template
            .iter()
            .zip(concrete)
            .all(|(t, c)| (t.starts_with('{') && t.ends_with('}')) || *t == c)
}
