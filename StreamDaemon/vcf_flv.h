#ifndef VCF_FLV_H
#define VCF_FLV_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>

typedef struct {
    FILE    *fp;
    char     path[512];
    char     tmp_path[520];
    uint32_t prev_tag_size;
    uint32_t tag_count;
    bool     has_audio;
    bool     has_video;
    bool     header_written;
} vcf_flv_writer_t;

// open a new FLV file for writing
vcf_flv_writer_t *vcf_flv_open(const char *path, bool audio, bool video);

// write an FLV tag (type: 8=audio, 9=video, 18=script)
int vcf_flv_write_tag(vcf_flv_writer_t *w, uint8_t type,
                       const uint8_t *data, uint32_t size, uint32_t timestamp);

// flush and atomically rename .tmp -> final path
int vcf_flv_flush(vcf_flv_writer_t *w);

// close without flushing (discard)
void vcf_flv_close(vcf_flv_writer_t *w);

// rolling writer: keeps the latest N seconds of stream in a file
// by periodically rotating to a new file
typedef struct {
    char             base_dir[512];
    vcf_flv_writer_t *current;
    vcf_flv_writer_t *latest;      // "latest.flv" — atomically swapped
    uint32_t          rotate_ms;   // rotate interval in ms
    uint32_t          start_ts;    // timestamp of first tag in current segment
    uint32_t          tag_count;
} vcf_flv_rolling_t;

vcf_flv_rolling_t *vcf_flv_rolling_open(const char *dir, uint32_t rotate_ms);
int  vcf_flv_rolling_write(vcf_flv_rolling_t *r, uint8_t type,
                            const uint8_t *data, uint32_t size, uint32_t timestamp);
void vcf_flv_rolling_close(vcf_flv_rolling_t *r);

#endif
