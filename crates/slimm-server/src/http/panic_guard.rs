// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A panic in a request handler answers that request with a 500 instead of
//! ending the process; a panic anywhere else still ends it.
//!
//! The release profile unwinds so a request panic can be caught at the router.
//! Background sweeps, socket tasks and anything spawned off a request have no
//! supervisor that would notice them dying, so for those [`install_hook`]
//! keeps the old abort-and-restart behavior. See decision 0059.

use std::any::Any;

use axum::extract::Request;
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use tower_http::catch_panic::CatchPanicLayer;

use super::error::ApiError;

tokio::task_local! {
    static IN_REQUEST: ();
}

type PanicResponse = fn(Box<dyn Any + Send + 'static>) -> Response;

/// Marks the request's own task, so the panic hook can tell it apart.
pub(super) async fn mark_request(request: Request, next: Next) -> Response {
    IN_REQUEST.scope((), next.run(request)).await
}

/// Turns a caught request panic into the same 500 an [`ApiError::Internal`] sends.
pub(super) fn catch_layer() -> CatchPanicLayer<PanicResponse> {
    CatchPanicLayer::custom(internal_error as PanicResponse)
}

fn internal_error(_panic: Box<dyn Any + Send + 'static>) -> Response {
    tracing::error!("a request handler panicked; answered 500");
    ApiError::Internal.into_response()
}

/// Whether a panic raised right now should end the process.
pub fn panic_ends_process() -> bool {
    IN_REQUEST.try_with(|_| ()).is_err()
}

/// Keeps the default report, then aborts unless the panic is on a request task.
pub fn install_hook() {
    let report = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        report(info);
        if panic_ends_process() {
            std::process::abort();
        }
    }));
}
