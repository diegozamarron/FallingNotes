// A small C wrapper around libx264 (GPL-2.0-or-later). See CX264.h.
#include "CX264.h"
#include "x264.h"
#include <stdlib.h>

struct cx264_encoder {
    x264_t *h;
    x264_param_t param;
};

cx264_encoder *cx264_open(int width, int height, int fps, int bitrate_kbps, int keyint, int threads, const char *preset) {
    cx264_encoder *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    x264_param_t *p = &e->param;
    if (x264_param_default_preset(p, preset, NULL) < 0) { free(e); return NULL; }
    p->i_width = width;
    p->i_height = height;
    p->i_csp = X264_CSP_NV12;
    p->i_fps_num = fps;
    p->i_fps_den = 1;
    p->i_timebase_num = 1;
    p->i_timebase_den = fps;
    p->b_vfr_input = 0;
    p->i_keyint_max = keyint;
    p->i_bframe = 0;                 // no B-frames: decode order equals display order, so segments join cleanly
    p->b_repeat_headers = 0;         // SPS/PPS live in the MP4 sample description, not in the stream
    p->b_annexb = 0;                 // length-prefixed NAL units, which is what MP4 stores
    p->rc.i_rc_method = X264_RC_ABR;
    p->rc.i_bitrate = bitrate_kbps;
    p->i_threads = threads;
    p->b_sliced_threads = 0;
    p->vui.b_fullrange = 0;          // video range, BT.709 (HD) colour
    p->vui.i_colorprim = 1;
    p->vui.i_transfer = 1;
    p->vui.i_colmatrix = 1;
    p->i_log_level = X264_LOG_NONE;
    if (x264_param_apply_profile(p, "high") < 0) { free(e); return NULL; }
    e->h = x264_encoder_open(p);
    if (!e->h) { free(e); return NULL; }
    return e;
}

int cx264_headers(cx264_encoder *e, const uint8_t **sps, int *sps_len, const uint8_t **pps, int *pps_len) {
    x264_nal_t *nal; int n = 0;
    if (x264_encoder_headers(e->h, &nal, &n) < 0) return -1;
    *sps = NULL; *pps = NULL;
    for (int i = 0; i < n; i++) {
        // each NAL starts with a 4-byte length because b_annexb is 0
        if (nal[i].i_type == NAL_SPS) { *sps = nal[i].p_payload + 4; *sps_len = nal[i].i_payload - 4; }
        if (nal[i].i_type == NAL_PPS) { *pps = nal[i].p_payload + 4; *pps_len = nal[i].i_payload - 4; }
    }
    return (*sps && *pps) ? 0 : -1;
}

int cx264_encode(cx264_encoder *e, const uint8_t *y, int y_stride, const uint8_t *uv, int uv_stride, int64_t pts,
                 const uint8_t **out, int *out_len, int *is_key, int64_t *out_pts) {
    x264_picture_t in, outp;
    x264_nal_t *nal; int n = 0;
    x264_picture_init(&outp);
    x264_picture_t *pin = NULL;
    if (y) {
        x264_picture_init(&in);
        in.img.i_csp = X264_CSP_NV12;
        in.img.i_plane = 2;
        in.img.plane[0] = (uint8_t *)y;  in.img.i_stride[0] = y_stride;
        in.img.plane[1] = (uint8_t *)uv; in.img.i_stride[1] = uv_stride;
        in.i_pts = pts;
        pin = &in;
    }
    int size = x264_encoder_encode(e->h, &nal, &n, pin, &outp);
    if (size < 0) return -1;
    if (size == 0) return 0;
    *out = nal[0].p_payload;         // all of a frame's NAL units are contiguous
    *out_len = size;
    *is_key = outp.b_keyframe;
    *out_pts = outp.i_pts;
    return 1;
}

int cx264_delayed(cx264_encoder *e) { return x264_encoder_delayed_frames(e->h); }

void cx264_close(cx264_encoder *e) {
    if (!e) return;
    x264_encoder_close(e->h);
    free(e);
}
