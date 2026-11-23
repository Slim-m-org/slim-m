// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `supervisor/1` error answer: `{"v":1,"error":"<code>","detail":"<text>"}`.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde::Serialize;

/// The error codes decision 0134 names, and nothing else.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Code {
    Unauthorized,
    BadRequest,
    Policy,
    NotFound,
    Conflict,
    Limit,
    RuntimeUnavailable,
}

impl Code {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unauthorized => "unauthorized",
            Self::BadRequest => "bad_request",
            Self::Policy => "policy",
            Self::NotFound => "not_found",
            Self::Conflict => "conflict",
            Self::Limit => "limit",
            Self::RuntimeUnavailable => "runtime_unavailable",
        }
    }

    fn status(self) -> StatusCode {
        match self {
            Self::Unauthorized => StatusCode::UNAUTHORIZED,
            Self::BadRequest => StatusCode::BAD_REQUEST,
            Self::Policy => StatusCode::FORBIDDEN,
            Self::NotFound => StatusCode::NOT_FOUND,
            Self::Conflict => StatusCode::CONFLICT,
            Self::Limit => StatusCode::UNPROCESSABLE_ENTITY,
            Self::RuntimeUnavailable => StatusCode::SERVICE_UNAVAILABLE,
        }
    }
}

/// A refused or failed request, with a human-readable reason for the admin.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApiError {
    pub code: Code,
    pub detail: String,
}

impl ApiError {
    pub fn new(code: Code, detail: impl Into<String>) -> Self {
        Self {
            code,
            detail: detail.into(),
        }
    }

    pub fn bad_request(detail: impl Into<String>) -> Self {
        Self::new(Code::BadRequest, detail)
    }

    pub fn policy(detail: impl Into<String>) -> Self {
        Self::new(Code::Policy, detail)
    }

    pub fn limit(detail: impl Into<String>) -> Self {
        Self::new(Code::Limit, detail)
    }

    pub fn runtime(detail: impl Into<String>) -> Self {
        Self::new(Code::RuntimeUnavailable, detail)
    }
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code.as_str(), self.detail)
    }
}

#[derive(Serialize)]
struct Body<'a> {
    v: u8,
    error: Code,
    detail: &'a str,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = Body {
            v: 1,
            error: self.code,
            detail: &self.detail,
        };
        (self.code.status(), axum::Json(body)).into_response()
    }
}
