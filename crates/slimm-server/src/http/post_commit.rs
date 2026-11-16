// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What to do with a failure after a message has committed, and with a
//! request that is dropped before it could announce one.

use std::future::Future;

use axum::extract::Request;
use axum::middleware::Next;
use axum::response::Response;

/// Middleware for a route that writes a message: the request runs to its end
/// even when the connection that made it closes or its timeout fires.
///
/// Either drops the handler wherever it is waiting, which can be between the
/// commit and the fan-out. The write is then stored, and the caller's retry
/// finds nothing left to do, so it publishes nothing and wakes nobody: the
/// other members would only learn of the send, edit or delete on their next
/// catch-up. Run on a task of its own, the write finishes whoever is still
/// listening.
pub(super) async fn run_to_completion(request: Request, next: Next) -> Response {
    to_completion(next.run(request)).await
}

async fn to_completion<T, F>(work: F) -> T
where
    F: Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    match super::panic_guard::spawn_request(work).await {
        Ok(done) => done,
        Err(failed) => match failed.try_into_panic() {
            // Raised again here, so the router's catch still answers it with a 500.
            Ok(panic) => std::panic::resume_unwind(panic),
            // Only a runtime that is shutting down cancels the task, and it drops this too.
            Err(_) => std::future::pending().await,
        },
    }
}

/// The value, or its default with the failure logged. Once a message is stored,
/// failing the request would make a retry see it as already sent and never
/// announce it, so the live event must still go out with what is available.
pub(super) fn after_commit<T: Default>(what: &str, result: anyhow::Result<T>) -> T {
    result.unwrap_or_else(|err| {
        tracing::warn!(%err, "message stored, but {what} failed");
        T::default()
    })
}

#[cfg(test)]
mod tests {
    use super::to_completion;

    #[tokio::test]
    async fn a_panic_in_the_work_is_raised_in_the_request_waiting_on_it() {
        let request = tokio::spawn(to_completion(async {
            panic!("the handler panicked");
        }));
        assert!(request.await.unwrap_err().is_panic());
    }

    #[tokio::test]
    async fn the_work_finishes_after_the_request_waiting_on_it_is_dropped() {
        let (started, has_started) = tokio::sync::oneshot::channel();
        let (done, finished) = tokio::sync::oneshot::channel();
        let request = tokio::spawn(to_completion(async move {
            let _ = started.send(());
            tokio::task::yield_now().await;
            let _ = done.send(());
        }));
        has_started.await.unwrap();
        request.abort();
        assert!(finished.await.is_ok());
    }
}
