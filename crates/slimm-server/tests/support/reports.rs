// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Filing a report under a freshly minted id, for tests that have no opinion about idempotency.

use slimm_server::ids::UserId;
use slimm_server::store::{ReportError, ReportSubject, Store};
use uuid::Uuid;

pub trait StoreReportExt {
    async fn file_report(
        &self,
        reporter: UserId,
        subject: ReportSubject,
        reason: &str,
    ) -> Result<Uuid, ReportError>;
}

impl StoreReportExt for Store {
    async fn file_report(
        &self,
        reporter: UserId,
        subject: ReportSubject,
        reason: &str,
    ) -> Result<Uuid, ReportError> {
        self.file_report_with_id(Uuid::now_v7(), reporter, subject, reason)
            .await
            .map(|filed| filed.id)
    }
}
