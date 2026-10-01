#ifndef VCF_RTMP_H
#define VCF_RTMP_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

// ── RTMP constants ──────────────────────────────
#define RTMP_VERSION            3
#define RTMP_HANDSHAKE_SIZE     1536
#define RTMP_DEFAULT_CHUNK_SIZE 128
#define RTMP_MAX_CHUNK_SIZE     65536
#define RTMP_DEFAULT_PORT       1935

// chunk stream IDs
#define RTMP_CSID_PROTOCOL      2
#define RTMP_CSID_COMMAND       3
#define RTMP_CSID_AUDIO         4
#define RTMP_CSID_VIDEO         5
#define RTMP_CSID_DATA          6

// message types
#define RTMP_MSG_SET_CHUNK_SIZE      1
#define RTMP_MSG_ABORT               2
#define RTMP_MSG_ACK                 3
#define RTMP_MSG_USER_CONTROL        4
#define RTMP_MSG_WIN_ACK_SIZE        5
#define RTMP_MSG_SET_PEER_BW         6
#define RTMP_MSG_AUDIO               8
#define RTMP_MSG_VIDEO               9
#define RTMP_MSG_AMF3_DATA          15
#define RTMP_MSG_AMF3_COMMAND       17
#define RTMP_MSG_AMF0_DATA          18
#define RTMP_MSG_AMF0_COMMAND       20
#define RTMP_MSG_AGGREGATE          22

// user control events
#define RTMP_UCM_STREAM_BEGIN   0
#define RTMP_UCM_STREAM_EOF     1
#define RTMP_UCM_STREAM_DRY     2
#define RTMP_UCM_PING_REQUEST   6
#define RTMP_UCM_PING_RESPONSE  7

// AMF0 types
#define AMF0_NUMBER     0x00
#define AMF0_BOOLEAN    0x01
#define AMF0_STRING     0x02
#define AMF0_OBJECT     0x03
#define AMF0_NULL       0x05
#define AMF0_UNDEFINED  0x06
#define AMF0_ECMA_ARRAY 0x08
#define AMF0_OBJ_END    0x09

// ── data structures ─────────────────────────────

typedef struct {
    uint8_t  *data;
    size_t    size;
    size_t    capacity;
    size_t    pos;       // read cursor
} vcf_buf_t;

typedef struct {
    uint32_t timestamp;
    uint32_t length;
    uint8_t  type_id;
    uint32_t stream_id;
    uint8_t *payload;
} rtmp_message_t;

typedef struct {
    uint32_t timestamp;
    uint32_t length;
    uint8_t  type_id;
    uint32_t stream_id;
    bool     has_header;
} rtmp_chunk_cache_t;

typedef struct rtmp_session {
    int       fd;
    bool      alive;

    uint32_t  in_chunk_size;
    uint32_t  out_chunk_size;
    uint32_t  in_window_size;
    uint32_t  out_window_size;
    uint64_t  in_bytes;
    uint64_t  in_bytes_acked;

    uint32_t  next_stream_id;
    bool      publishing;
    char      publish_name[256];

    rtmp_chunk_cache_t in_cache[64];

    // FLV writer callback
    void    (*on_audio)(struct rtmp_session *s, const uint8_t *data, size_t len, uint32_t ts);
    void    (*on_video)(struct rtmp_session *s, const uint8_t *data, size_t len, uint32_t ts);
    void    (*on_script)(struct rtmp_session *s, const uint8_t *data, size_t len, uint32_t ts);
    void     *userdata;
} rtmp_session_t;

// ── API ─────────────────────────────────────────

// session lifecycle
rtmp_session_t *rtmp_session_create(int client_fd);
void            rtmp_session_destroy(rtmp_session_t *s);

// handshake (blocking)
int rtmp_handshake(rtmp_session_t *s);

// main loop: read chunks, dispatch messages. returns 0 on clean close, -1 on error
int rtmp_session_run(rtmp_session_t *s);

// ── AMF0 helpers ────────────────────────────────
void    vcf_buf_init(vcf_buf_t *b, size_t cap);
void    vcf_buf_free(vcf_buf_t *b);
void    vcf_buf_reset(vcf_buf_t *b);
void    vcf_buf_write(vcf_buf_t *b, const void *data, size_t len);
void    vcf_buf_write_u8(vcf_buf_t *b, uint8_t v);
void    vcf_buf_write_u16be(vcf_buf_t *b, uint16_t v);
void    vcf_buf_write_u24be(vcf_buf_t *b, uint32_t v);
void    vcf_buf_write_u32be(vcf_buf_t *b, uint32_t v);
void    vcf_buf_write_u32le(vcf_buf_t *b, uint32_t v);

// AMF0 write
void    amf0_write_number(vcf_buf_t *b, double v);
void    amf0_write_boolean(vcf_buf_t *b, bool v);
void    amf0_write_string(vcf_buf_t *b, const char *str);
void    amf0_write_null(vcf_buf_t *b);
void    amf0_write_object_start(vcf_buf_t *b);
void    amf0_write_object_key(vcf_buf_t *b, const char *key);
void    amf0_write_object_end(vcf_buf_t *b);

// AMF0 read
double      amf0_read_number(const uint8_t **p, const uint8_t *end);
bool        amf0_read_boolean(const uint8_t **p, const uint8_t *end);
char       *amf0_read_string(const uint8_t **p, const uint8_t *end);
int         amf0_skip_value(const uint8_t **p, const uint8_t *end);

#endif
