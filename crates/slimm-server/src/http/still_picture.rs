// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The one check every profile-style picture passes: an avatar, the Space
//! icon and the banner are still images of a bounded size.

use super::error::ApiError;
use crate::media::{self, ImageProblem, Motion};

/// The refusal for each way a picture can be wrong, worded for its surface.
pub(super) struct Refusals {
    pub unsupported: &'static str,
    pub animated: &'static str,
    pub too_large: &'static str,
}

/// Refuses anything but a still picture no larger than
/// [`media::MAX_PROFILE_IMAGE_SIDE`] on a side.
pub(super) fn require_still_picture(bytes: &[u8], refusals: &Refusals) -> Result<(), ApiError> {
    media::check_image(bytes, Motion::StillOnly, media::MAX_PROFILE_IMAGE_SIDE)
        .map(drop)
        .map_err(|problem| {
            ApiError::BadRequest(match problem {
                ImageProblem::Unsupported => refusals.unsupported,
                ImageProblem::Animated => refusals.animated,
                ImageProblem::TooLarge => refusals.too_large,
            })
        })
}
