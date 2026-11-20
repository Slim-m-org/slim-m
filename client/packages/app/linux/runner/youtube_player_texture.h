// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_YOUTUBE_PLAYER_TEXTURE_H_
#define RUNNER_YOUTUBE_PLAYER_TEXTURE_H_

#include <cairo.h>
#include <flutter_linux/flutter_linux.h>

G_DECLARE_FINAL_TYPE(SlimmVideoTexture, slimm_video_texture, SLIMM,
                     VIDEO_TEXTURE, FlPixelBufferTexture)

/// The YouTube player's frames as a Flutter texture. The main thread stores
/// each captured frame; Flutter reads the newest one on its raster thread.
SlimmVideoTexture* slimm_video_texture_new();

/// Keeps [image], a cairo ARGB32 surface, as the next frame Flutter reads.
void slimm_video_texture_store(SlimmVideoTexture* self, cairo_surface_t* image);

#endif  // RUNNER_YOUTUBE_PLAYER_TEXTURE_H_
