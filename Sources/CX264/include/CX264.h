// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Diego Zamarron
// A small C wrapper around libx264 (GPL-2.0-or-later), so Swift can use it without the version-mangled macros.
#ifndef CX264_H
#define CX264_H
#include <stdint.h>

typedef struct cx264_encoder cx264_encoder;

/// Opens an 8-bit 4:2:0 H.264 encoder fed with NV12 frames. Output is length-prefixed (MP4/AVCC style) with the
/// parameter sets kept out of the stream (get them from cx264_headers). Returns NULL on failure.
cx264_encoder *cx264_open(int width, int height, int fps, int bitrate_kbps, int keyint, int threads, const char *preset);

/// The raw SPS and PPS (no length prefix); the pointers stay valid until the next encode call.
int cx264_headers(cx264_encoder *e, const uint8_t **sps, int *sps_len, const uint8_t **pps, int *pps_len);

/// Encodes one NV12 frame (or flushes one delayed frame when `y` is NULL). Returns 1 and fills `out`/`out_len`
/// (valid until the next call) when a compressed frame is ready, 0 when the encoder is still buffering, -1 on error.
int cx264_encode(cx264_encoder *e, const uint8_t *y, int y_stride, const uint8_t *uv, int uv_stride, int64_t pts,
                 const uint8_t **out, int *out_len, int *is_key, int64_t *out_pts);

/// Number of frames still buffered inside the encoder.
int cx264_delayed(cx264_encoder *e);

void cx264_close(cx264_encoder *e);

#endif
