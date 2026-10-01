#include "vcf_flv.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// ── FLV file format helpers ─────────────────────

static void write_u24be(FILE *fp, uint32_t v) {
    uint8_t b[3] = { (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
    fwrite(b, 1, 3, fp);
}

static void write_u32be(FILE *fp, uint32_t v) {
    uint8_t b[4] = { (uint8_t)(v >> 24), (uint8_t)(v >> 16),
                     (uint8_t)(v >> 8), (uint8_t)v };
    fwrite(b, 1, 4, fp);
}

static int write_flv_header(vcf_flv_writer_t *w) {
    uint8_t hdr[9];
    hdr[0] = 'F'; hdr[1] = 'L'; hdr[2] = 'V';
    hdr[3] = 0x01; // version
    hdr[4] = (w->has_audio ? 0x04 : 0) | (w->has_video ? 0x01 : 0);
    // data offset = 9
    hdr[5] = 0; hdr[6] = 0; hdr[7] = 0; hdr[8] = 9;
    fwrite(hdr, 1, 9, w->fp);
    // previous tag size 0
    write_u32be(w->fp, 0);
    w->header_written = true;
    return 0;
}

// ── writer ──────────────────────────────────────

vcf_flv_writer_t *vcf_flv_open(const char *path, bool audio, bool video) {
    vcf_flv_writer_t *w = calloc(1, sizeof(*w));
    snprintf(w->path, sizeof(w->path), "%s", path);
    snprintf(w->tmp_path, sizeof(w->tmp_path), "%s.tmp", path);

    w->fp = fopen(w->tmp_path, "wb");
    if (!w->fp) { free(w); return NULL; }

    w->has_audio = audio;
    w->has_video = video;
    write_flv_header(w);
    return w;
}

int vcf_flv_write_tag(vcf_flv_writer_t *w, uint8_t type,
                       const uint8_t *data, uint32_t size, uint32_t timestamp) {
    if (!w || !w->fp) return -1;

    // tag header: type(1) + dataSize(3) + timestamp(3) + timestampExt(1) + streamId(3) = 11
    fputc(type, w->fp);
    write_u24be(w->fp, size);
    write_u24be(w->fp, timestamp & 0xFFFFFF);
    fputc((uint8_t)(timestamp >> 24), w->fp); // extended timestamp
    write_u24be(w->fp, 0); // stream ID always 0

    // tag data
    if (size > 0 && data) {
        fwrite(data, 1, size, w->fp);
    }

    // previous tag size
    uint32_t tagTotalSize = 11 + size;
    write_u32be(w->fp, tagTotalSize);
    w->prev_tag_size = tagTotalSize;
    w->tag_count++;

    return 0;
}

int vcf_flv_flush(vcf_flv_writer_t *w) {
    if (!w) return -1;
    if (w->fp) {
        fflush(w->fp);
        fclose(w->fp);
        w->fp = NULL;
    }
    rename(w->tmp_path, w->path);
    return 0;
}

void vcf_flv_close(vcf_flv_writer_t *w) {
    if (!w) return;
    if (w->fp) fclose(w->fp);
    unlink(w->tmp_path);
    free(w);
}

// ── rolling writer ──────────────────────────────

vcf_flv_rolling_t *vcf_flv_rolling_open(const char *dir, uint32_t rotate_ms) {
    vcf_flv_rolling_t *r = calloc(1, sizeof(*r));
    snprintf(r->base_dir, sizeof(r->base_dir), "%s", dir);
    r->rotate_ms = rotate_ms > 0 ? rotate_ms : 5000; // default 5s segments
    return r;
}

static void rolling_rotate(vcf_flv_rolling_t *r) {
    // flush current to latest.flv
    if (r->current) {
        vcf_flv_flush(r->current);
        free(r->current);
        r->current = NULL;
    }

    // start new live segment
    char live_path[600];
    snprintf(live_path, sizeof(live_path), "%s/live.vcf", r->base_dir);
    r->current = vcf_flv_open(live_path, true, true);
    r->tag_count = 0;
}

int vcf_flv_rolling_write(vcf_flv_rolling_t *r, uint8_t type,
                            const uint8_t *data, uint32_t size, uint32_t timestamp) {
    if (!r) return -1;

    // first write or time to rotate
    if (!r->current) {
        r->start_ts = timestamp;
        rolling_rotate(r);
    } else if (timestamp - r->start_ts >= r->rotate_ms) {
        r->start_ts = timestamp;
        rolling_rotate(r);
    }

    if (!r->current) return -1;

    int ret = vcf_flv_write_tag(r->current, type, data, size, timestamp);

    // also write to latest.flv (always has the most recent keyframe + data)
    char latest_path[600];
    snprintf(latest_path, sizeof(latest_path), "%s/latest.flv", r->base_dir);

    // on each video keyframe, restart latest.flv
    if (type == 9 && size > 0 && ((data[0] >> 4) & 0x0F) == 1) {
        if (r->latest) {
            vcf_flv_flush(r->latest);
            free(r->latest);
        }
        r->latest = vcf_flv_open(latest_path, true, true);
    }
    if (r->latest) {
        vcf_flv_write_tag(r->latest, type, data, size, timestamp);
        if (r->latest->fp) fflush(r->latest->fp);
    }

    return ret;
}

void vcf_flv_rolling_close(vcf_flv_rolling_t *r) {
    if (!r) return;
    if (r->current) { vcf_flv_close(r->current); }
    if (r->latest) { vcf_flv_flush(r->latest); free(r->latest); }
    free(r);
}
