#include "vcf_rtmp.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <time.h>

// ── buffer helpers ──────────────────────────────

void vcf_buf_init(vcf_buf_t *b, size_t cap) {
    b->data = calloc(1, cap);
    b->size = 0;
    b->capacity = cap;
    b->pos = 0;
}

void vcf_buf_free(vcf_buf_t *b) {
    free(b->data);
    memset(b, 0, sizeof(*b));
}

void vcf_buf_reset(vcf_buf_t *b) {
    b->size = 0;
    b->pos = 0;
}

static void vcf_buf_grow(vcf_buf_t *b, size_t need) {
    if (b->size + need <= b->capacity) return;
    size_t newcap = b->capacity * 2;
    if (newcap < b->size + need) newcap = b->size + need + 4096;
    b->data = realloc(b->data, newcap);
    b->capacity = newcap;
}

void vcf_buf_write(vcf_buf_t *b, const void *data, size_t len) {
    vcf_buf_grow(b, len);
    memcpy(b->data + b->size, data, len);
    b->size += len;
}

void vcf_buf_write_u8(vcf_buf_t *b, uint8_t v) { vcf_buf_write(b, &v, 1); }

void vcf_buf_write_u16be(vcf_buf_t *b, uint16_t v) {
    uint8_t buf[2] = { (uint8_t)(v >> 8), (uint8_t)v };
    vcf_buf_write(b, buf, 2);
}

void vcf_buf_write_u24be(vcf_buf_t *b, uint32_t v) {
    uint8_t buf[3] = { (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
    vcf_buf_write(b, buf, 3);
}

void vcf_buf_write_u32be(vcf_buf_t *b, uint32_t v) {
    uint8_t buf[4] = { (uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
    vcf_buf_write(b, buf, 4);
}

void vcf_buf_write_u32le(vcf_buf_t *b, uint32_t v) {
    uint8_t buf[4] = { (uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24) };
    vcf_buf_write(b, buf, 4);
}

// ── reliable I/O ────────────────────────────────

static ssize_t sock_read_full(int fd, void *buf, size_t len) {
    size_t total = 0;
    while (total < len) {
        ssize_t n = read(fd, (uint8_t *)buf + total, len - total);
        if (n <= 0) return -1;
        total += (size_t)n;
    }
    return (ssize_t)total;
}

static ssize_t sock_write_full(int fd, const void *buf, size_t len) {
    size_t total = 0;
    while (total < len) {
        ssize_t n = write(fd, (const uint8_t *)buf + total, len - total);
        if (n <= 0) return -1;
        total += (size_t)n;
    }
    return (ssize_t)total;
}

// ── AMF0 write ──────────────────────────────────

void amf0_write_number(vcf_buf_t *b, double v) {
    vcf_buf_write_u8(b, AMF0_NUMBER);
    union { double d; uint64_t u; } cv;
    cv.d = v;
    uint8_t buf[8];
    for (int i = 7; i >= 0; i--) { buf[7 - i] = (uint8_t)(cv.u >> (i * 8)); }
    vcf_buf_write(b, buf, 8);
}

void amf0_write_boolean(vcf_buf_t *b, bool v) {
    vcf_buf_write_u8(b, AMF0_BOOLEAN);
    vcf_buf_write_u8(b, v ? 1 : 0);
}

void amf0_write_string(vcf_buf_t *b, const char *str) {
    size_t len = strlen(str);
    vcf_buf_write_u8(b, AMF0_STRING);
    vcf_buf_write_u16be(b, (uint16_t)len);
    vcf_buf_write(b, str, len);
}

void amf0_write_null(vcf_buf_t *b) {
    vcf_buf_write_u8(b, AMF0_NULL);
}

void amf0_write_object_start(vcf_buf_t *b) {
    vcf_buf_write_u8(b, AMF0_OBJECT);
}

void amf0_write_object_key(vcf_buf_t *b, const char *key) {
    size_t len = strlen(key);
    vcf_buf_write_u16be(b, (uint16_t)len);
    vcf_buf_write(b, key, len);
}

void amf0_write_object_end(vcf_buf_t *b) {
    vcf_buf_write_u16be(b, 0);
    vcf_buf_write_u8(b, AMF0_OBJ_END);
}

// ── AMF0 read ───────────────────────────────────

static uint16_t read_u16be(const uint8_t **p) {
    uint16_t v = ((uint16_t)(*p)[0] << 8) | (*p)[1];
    *p += 2;
    return v;
}

static uint32_t __attribute__((unused)) read_u32be(const uint8_t **p) {
    uint32_t v = ((uint32_t)(*p)[0] << 24) | ((uint32_t)(*p)[1] << 16) |
                 ((uint32_t)(*p)[2] << 8) | (*p)[3];
    *p += 4;
    return v;
}

double amf0_read_number(const uint8_t **p, const uint8_t *end) {
    if (*p + 9 > end) return 0;
    if (**p != AMF0_NUMBER) return 0;
    (*p)++;
    union { double d; uint64_t u; } cv;
    cv.u = 0;
    for (int i = 0; i < 8; i++) cv.u = (cv.u << 8) | (*p)[i];
    *p += 8;
    return cv.d;
}

bool amf0_read_boolean(const uint8_t **p, const uint8_t *end) {
    if (*p + 2 > end) return false;
    (*p)++;
    bool v = (**p != 0);
    (*p)++;
    return v;
}

char *amf0_read_string(const uint8_t **p, const uint8_t *end) {
    if (*p + 3 > end) return NULL;
    (*p)++; // skip type
    uint16_t len = read_u16be(p);
    if (*p + len > end) return NULL;
    char *s = malloc(len + 1);
    memcpy(s, *p, len);
    s[len] = '\0';
    *p += len;
    return s;
}

int amf0_skip_value(const uint8_t **p, const uint8_t *end) {
    if (*p >= end) return -1;
    uint8_t type = **p;
    (*p)++;
    switch (type) {
        case AMF0_NUMBER:    *p += 8; break;
        case AMF0_BOOLEAN:   *p += 1; break;
        case AMF0_STRING: {
            if (*p + 2 > end) return -1;
            uint16_t len = read_u16be(p);
            *p += len;
            break;
        }
        case AMF0_OBJECT: {
            while (*p + 3 <= end) {
                uint16_t klen = read_u16be(p);
                if (klen == 0 && **p == AMF0_OBJ_END) { (*p)++; break; }
                *p += klen;
                if (amf0_skip_value(p, end) < 0) return -1;
            }
            break;
        }
        case AMF0_NULL:
        case AMF0_UNDEFINED:
            break;
        case AMF0_ECMA_ARRAY: {
            if (*p + 4 > end) return -1;
            *p += 4; // count
            while (*p + 3 <= end) {
                uint16_t klen = read_u16be(p);
                if (klen == 0 && **p == AMF0_OBJ_END) { (*p)++; break; }
                *p += klen;
                if (amf0_skip_value(p, end) < 0) return -1;
            }
            break;
        }
        default:
            return -1;
    }
    return 0;
}

// ── session ─────────────────────────────────────

rtmp_session_t *rtmp_session_create(int client_fd) {
    rtmp_session_t *s = calloc(1, sizeof(rtmp_session_t));
    s->fd = client_fd;
    s->alive = true;
    s->in_chunk_size = RTMP_DEFAULT_CHUNK_SIZE;
    s->out_chunk_size = RTMP_DEFAULT_CHUNK_SIZE;
    s->in_window_size = 2500000;
    s->out_window_size = 2500000;
    s->next_stream_id = 1;
    return s;
}

void rtmp_session_destroy(rtmp_session_t *s) {
    if (!s) return;
    for (int i = 0; i < 64; i++) {
        // chunk caches don't own payload memory
    }
    close(s->fd);
    free(s);
}

// ── handshake ───────────────────────────────────

int rtmp_handshake(rtmp_session_t *s) {
    // C0
    uint8_t c0;
    if (sock_read_full(s->fd, &c0, 1) < 0) return -1;
    if (c0 != RTMP_VERSION) {
        fprintf(stderr, "[rtmp] bad version %d\n", c0);
        return -1;
    }

    // C1
    uint8_t c1[RTMP_HANDSHAKE_SIZE];
    if (sock_read_full(s->fd, c1, RTMP_HANDSHAKE_SIZE) < 0) return -1;

    // S0
    uint8_t s0 = RTMP_VERSION;
    if (sock_write_full(s->fd, &s0, 1) < 0) return -1;

    // S1
    uint8_t s1[RTMP_HANDSHAKE_SIZE];
    uint32_t now = (uint32_t)time(NULL);
    s1[0] = (uint8_t)(now >> 24); s1[1] = (uint8_t)(now >> 16);
    s1[2] = (uint8_t)(now >> 8);  s1[3] = (uint8_t)now;
    memset(s1 + 4, 0, 4); // zero
    arc4random_buf(s1 + 8, RTMP_HANDSHAKE_SIZE - 8);
    if (sock_write_full(s->fd, s1, RTMP_HANDSHAKE_SIZE) < 0) return -1;

    // S2 = echo of C1
    if (sock_write_full(s->fd, c1, RTMP_HANDSHAKE_SIZE) < 0) return -1;

    // C2
    uint8_t c2[RTMP_HANDSHAKE_SIZE];
    if (sock_read_full(s->fd, c2, RTMP_HANDSHAKE_SIZE) < 0) return -1;

    fprintf(stderr, "[rtmp] handshake complete\n");
    return 0;
}

// ── chunk read ──────────────────────────────────

static int rtmp_read_basic_header(rtmp_session_t *s, uint8_t *fmt, uint32_t *csid) {
    uint8_t b;
    if (sock_read_full(s->fd, &b, 1) < 0) return -1;
    s->in_bytes++;

    *fmt = (b >> 6) & 0x03;
    *csid = b & 0x3F;

    if (*csid == 0) {
        uint8_t b2;
        if (sock_read_full(s->fd, &b2, 1) < 0) return -1;
        s->in_bytes++;
        *csid = (uint32_t)b2 + 64;
    } else if (*csid == 1) {
        uint8_t b2[2];
        if (sock_read_full(s->fd, b2, 2) < 0) return -1;
        s->in_bytes += 2;
        *csid = ((uint32_t)b2[1] << 8) + (uint32_t)b2[0] + 64;
    }
    return 0;
}

static int rtmp_read_message_header(rtmp_session_t *s, uint8_t fmt, uint32_t csid,
                                     rtmp_chunk_cache_t *cache) {
    uint8_t hdr[11];

    switch (fmt) {
        case 0: { // full header (11 bytes)
            if (sock_read_full(s->fd, hdr, 11) < 0) return -1;
            s->in_bytes += 11;
            cache->timestamp = ((uint32_t)hdr[0] << 16) | ((uint32_t)hdr[1] << 8) | hdr[2];
            cache->length    = ((uint32_t)hdr[3] << 16) | ((uint32_t)hdr[4] << 8) | hdr[5];
            cache->type_id   = hdr[6];
            cache->stream_id = (uint32_t)hdr[7] | ((uint32_t)hdr[8] << 8) |
                               ((uint32_t)hdr[9] << 16) | ((uint32_t)hdr[10] << 24);
            cache->has_header = true;
            break;
        }
        case 1: { // 7 bytes (no stream_id)
            if (sock_read_full(s->fd, hdr, 7) < 0) return -1;
            s->in_bytes += 7;
            cache->timestamp = ((uint32_t)hdr[0] << 16) | ((uint32_t)hdr[1] << 8) | hdr[2];
            cache->length    = ((uint32_t)hdr[3] << 16) | ((uint32_t)hdr[4] << 8) | hdr[5];
            cache->type_id   = hdr[6];
            cache->has_header = true;
            break;
        }
        case 2: { // 3 bytes (timestamp delta only)
            if (sock_read_full(s->fd, hdr, 3) < 0) return -1;
            s->in_bytes += 3;
            cache->timestamp = ((uint32_t)hdr[0] << 16) | ((uint32_t)hdr[1] << 8) | hdr[2];
            break;
        }
        case 3: // 0 bytes, reuse previous
            break;
    }

    // extended timestamp
    if (cache->timestamp == 0xFFFFFF) {
        uint8_t ext[4];
        if (sock_read_full(s->fd, ext, 4) < 0) return -1;
        s->in_bytes += 4;
        cache->timestamp = ((uint32_t)ext[0] << 24) | ((uint32_t)ext[1] << 16) |
                           ((uint32_t)ext[2] << 8) | ext[3];
    }

    return 0;
}

// ── chunk write ─────────────────────────────────

static int rtmp_send_message(rtmp_session_t *s, uint8_t type_id, uint32_t stream_id,
                              uint32_t csid, const uint8_t *data, uint32_t len, uint32_t ts) {
    // fmt 0 header
    vcf_buf_t buf;
    vcf_buf_init(&buf, 12 + len + (len / s->out_chunk_size + 1));

    // basic header (1 byte for csid < 64)
    uint8_t bh = (0 << 6) | (csid & 0x3F);
    vcf_buf_write_u8(&buf, bh);

    // message header (11 bytes, fmt 0)
    uint32_t ts_field = (ts >= 0xFFFFFF) ? 0xFFFFFF : ts;
    vcf_buf_write_u24be(&buf, ts_field);
    vcf_buf_write_u24be(&buf, len);
    vcf_buf_write_u8(&buf, type_id);
    vcf_buf_write_u32le(&buf, stream_id); // little-endian!

    if (ts >= 0xFFFFFF) {
        vcf_buf_write_u32be(&buf, ts);
    }

    // chunk data with continuation headers
    uint32_t remaining = len;
    const uint8_t *p = data;
    while (remaining > 0) {
        uint32_t chunk = remaining;
        if (chunk > s->out_chunk_size) chunk = s->out_chunk_size;
        vcf_buf_write(&buf, p, chunk);
        p += chunk;
        remaining -= chunk;

        if (remaining > 0) {
            // fmt 3 continuation header
            uint8_t cont = (3 << 6) | (csid & 0x3F);
            vcf_buf_write_u8(&buf, cont);
        }
    }

    ssize_t r = sock_write_full(s->fd, buf.data, buf.size);
    vcf_buf_free(&buf);
    return (r < 0) ? -1 : 0;
}

// ── protocol control messages ───────────────────

static int rtmp_send_set_chunk_size(rtmp_session_t *s, uint32_t size) {
    uint8_t data[4];
    data[0] = (uint8_t)(size >> 24) & 0x7F;
    data[1] = (uint8_t)(size >> 16);
    data[2] = (uint8_t)(size >> 8);
    data[3] = (uint8_t)size;
    s->out_chunk_size = size;
    return rtmp_send_message(s, RTMP_MSG_SET_CHUNK_SIZE, 0, RTMP_CSID_PROTOCOL, data, 4, 0);
}

static int rtmp_send_window_ack_size(rtmp_session_t *s, uint32_t size) {
    uint8_t data[4];
    data[0] = (uint8_t)(size >> 24);
    data[1] = (uint8_t)(size >> 16);
    data[2] = (uint8_t)(size >> 8);
    data[3] = (uint8_t)size;
    return rtmp_send_message(s, RTMP_MSG_WIN_ACK_SIZE, 0, RTMP_CSID_PROTOCOL, data, 4, 0);
}

static int rtmp_send_set_peer_bw(rtmp_session_t *s, uint32_t bw, uint8_t limit_type) {
    uint8_t data[5];
    data[0] = (uint8_t)(bw >> 24);
    data[1] = (uint8_t)(bw >> 16);
    data[2] = (uint8_t)(bw >> 8);
    data[3] = (uint8_t)bw;
    data[4] = limit_type;
    return rtmp_send_message(s, RTMP_MSG_SET_PEER_BW, 0, RTMP_CSID_PROTOCOL, data, 5, 0);
}

static int rtmp_send_user_control(rtmp_session_t *s, uint16_t event, uint32_t value) {
    uint8_t data[6];
    data[0] = (uint8_t)(event >> 8);
    data[1] = (uint8_t)event;
    data[2] = (uint8_t)(value >> 24);
    data[3] = (uint8_t)(value >> 16);
    data[4] = (uint8_t)(value >> 8);
    data[5] = (uint8_t)value;
    return rtmp_send_message(s, RTMP_MSG_USER_CONTROL, 0, RTMP_CSID_PROTOCOL, data, 6, 0);
}

static int rtmp_send_ack(rtmp_session_t *s) {
    uint8_t data[4];
    uint32_t seq = (uint32_t)s->in_bytes;
    data[0] = (uint8_t)(seq >> 24);
    data[1] = (uint8_t)(seq >> 16);
    data[2] = (uint8_t)(seq >> 8);
    data[3] = (uint8_t)seq;
    s->in_bytes_acked = s->in_bytes;
    return rtmp_send_message(s, RTMP_MSG_ACK, 0, RTMP_CSID_PROTOCOL, data, 4, 0);
}

// ── command responses ───────────────────────────

static int rtmp_send_connect_result(rtmp_session_t *s, double txn_id) {
    vcf_buf_t buf;
    vcf_buf_init(&buf, 512);

    amf0_write_string(&buf, "_result");
    amf0_write_number(&buf, txn_id);

    // properties
    amf0_write_object_start(&buf);
    amf0_write_object_key(&buf, "fmsVer");
    amf0_write_string(&buf, "FMS/3,0,1,123");
    amf0_write_object_key(&buf, "capabilities");
    amf0_write_number(&buf, 31);
    amf0_write_object_end(&buf);

    // information
    amf0_write_object_start(&buf);
    amf0_write_object_key(&buf, "level");
    amf0_write_string(&buf, "status");
    amf0_write_object_key(&buf, "code");
    amf0_write_string(&buf, "NetConnection.Connect.Success");
    amf0_write_object_key(&buf, "description");
    amf0_write_string(&buf, "Connection accepted.");
    amf0_write_object_key(&buf, "objectEncoding");
    amf0_write_number(&buf, 0);
    amf0_write_object_end(&buf);

    int r = rtmp_send_message(s, RTMP_MSG_AMF0_COMMAND, 0, RTMP_CSID_COMMAND,
                              buf.data, (uint32_t)buf.size, 0);
    vcf_buf_free(&buf);
    return r;
}

static int rtmp_send_create_stream_result(rtmp_session_t *s, double txn_id, double stream_id) {
    vcf_buf_t buf;
    vcf_buf_init(&buf, 64);

    amf0_write_string(&buf, "_result");
    amf0_write_number(&buf, txn_id);
    amf0_write_null(&buf);
    amf0_write_number(&buf, stream_id);

    int r = rtmp_send_message(s, RTMP_MSG_AMF0_COMMAND, 0, RTMP_CSID_COMMAND,
                              buf.data, (uint32_t)buf.size, 0);
    vcf_buf_free(&buf);
    return r;
}

static int rtmp_send_on_status(rtmp_session_t *s, uint32_t stream_id,
                                const char *code, const char *desc) {
    vcf_buf_t buf;
    vcf_buf_init(&buf, 256);

    amf0_write_string(&buf, "onStatus");
    amf0_write_number(&buf, 0);
    amf0_write_null(&buf);

    amf0_write_object_start(&buf);
    amf0_write_object_key(&buf, "level");
    amf0_write_string(&buf, "status");
    amf0_write_object_key(&buf, "code");
    amf0_write_string(&buf, code);
    amf0_write_object_key(&buf, "description");
    amf0_write_string(&buf, desc);
    amf0_write_object_end(&buf);

    int r = rtmp_send_message(s, RTMP_MSG_AMF0_COMMAND, stream_id, RTMP_CSID_COMMAND,
                              buf.data, (uint32_t)buf.size, 0);
    vcf_buf_free(&buf);
    return r;
}

static int rtmp_send_on_fc_publish(rtmp_session_t *s) {
    vcf_buf_t buf;
    vcf_buf_init(&buf, 64);
    amf0_write_string(&buf, "onFCPublish");
    amf0_write_number(&buf, 0);
    amf0_write_null(&buf);
    int r = rtmp_send_message(s, RTMP_MSG_AMF0_COMMAND, 0, RTMP_CSID_COMMAND,
                              buf.data, (uint32_t)buf.size, 0);
    vcf_buf_free(&buf);
    return r;
}

// ── command dispatch ────────────────────────────

static int rtmp_handle_command(rtmp_session_t *s, rtmp_message_t *msg) {
    const uint8_t *p = msg->payload;
    const uint8_t *end = p + msg->length;

    if (p >= end || *p != AMF0_STRING) return -1;
    char *cmd = amf0_read_string(&p, end);
    if (!cmd) return -1;

    double txn_id = 0;
    if (p < end && *p == AMF0_NUMBER) {
        txn_id = amf0_read_number(&p, end);
    }

    fprintf(stderr, "[rtmp] command: %s txn=%.0f\n", cmd, txn_id);

    if (strcmp(cmd, "connect") == 0) {
        // skip command object
        if (p < end) amf0_skip_value(&p, end);

        rtmp_send_window_ack_size(s, s->out_window_size);
        rtmp_send_set_peer_bw(s, s->out_window_size, 2);
        rtmp_send_set_chunk_size(s, 4096);
        rtmp_send_user_control(s, RTMP_UCM_STREAM_BEGIN, 0);
        rtmp_send_connect_result(s, txn_id);

    } else if (strcmp(cmd, "releaseStream") == 0 ||
               strcmp(cmd, "FCPublish") == 0) {
        // skip null + stream name
        if (p < end) amf0_skip_value(&p, end);
        if (p < end && *p == AMF0_STRING) {
            char *name = amf0_read_string(&p, end);
            if (name) {
                snprintf(s->publish_name, sizeof(s->publish_name), "%s", name);
                free(name);
            }
        }
        if (strcmp(cmd, "FCPublish") == 0) {
            rtmp_send_on_fc_publish(s);
        }

    } else if (strcmp(cmd, "createStream") == 0) {
        double sid = (double)s->next_stream_id++;
        rtmp_send_create_stream_result(s, txn_id, sid);

    } else if (strcmp(cmd, "publish") == 0) {
        // skip null
        if (p < end) amf0_skip_value(&p, end);
        // stream name
        if (p < end && *p == AMF0_STRING) {
            char *name = amf0_read_string(&p, end);
            if (name) {
                snprintf(s->publish_name, sizeof(s->publish_name), "%s", name);
                free(name);
            }
        }
        s->publishing = true;
        fprintf(stderr, "[rtmp] publish started: %s\n", s->publish_name);

        rtmp_send_user_control(s, RTMP_UCM_STREAM_BEGIN, msg->stream_id);
        rtmp_send_on_status(s, msg->stream_id,
                            "NetStream.Publish.Start", "Publishing started.");

    } else if (strcmp(cmd, "FCUnpublish") == 0 ||
               strcmp(cmd, "deleteStream") == 0 ||
               strcmp(cmd, "closeStream") == 0) {
        s->publishing = false;
        fprintf(stderr, "[rtmp] stream closed\n");

    } else if (strcmp(cmd, "_checkbw") == 0 ||
               strcmp(cmd, "onBWDone") == 0) {
        // ignore
    }

    free(cmd);
    return 0;
}

// ── message dispatch ────────────────────────────

static int rtmp_handle_message(rtmp_session_t *s, rtmp_message_t *msg) {
    switch (msg->type_id) {
        case RTMP_MSG_SET_CHUNK_SIZE: {
            if (msg->length >= 4) {
                s->in_chunk_size = ((uint32_t)msg->payload[0] << 24) |
                                   ((uint32_t)msg->payload[1] << 16) |
                                   ((uint32_t)msg->payload[2] << 8) |
                                   msg->payload[3];
                s->in_chunk_size &= 0x7FFFFFFF;
                fprintf(stderr, "[rtmp] chunk size -> %u\n", s->in_chunk_size);
            }
            break;
        }
        case RTMP_MSG_ABORT:
            break;

        case RTMP_MSG_ACK:
            break;

        case RTMP_MSG_WIN_ACK_SIZE: {
            if (msg->length >= 4) {
                s->in_window_size = ((uint32_t)msg->payload[0] << 24) |
                                    ((uint32_t)msg->payload[1] << 16) |
                                    ((uint32_t)msg->payload[2] << 8) |
                                    msg->payload[3];
            }
            break;
        }
        case RTMP_MSG_SET_PEER_BW:
            break;

        case RTMP_MSG_USER_CONTROL: {
            if (msg->length >= 6) {
                uint16_t event = ((uint16_t)msg->payload[0] << 8) | msg->payload[1];
                uint32_t val = ((uint32_t)msg->payload[2] << 24) |
                               ((uint32_t)msg->payload[3] << 16) |
                               ((uint32_t)msg->payload[4] << 8) | msg->payload[5];
                if (event == RTMP_UCM_PING_REQUEST) {
                    rtmp_send_user_control(s, RTMP_UCM_PING_RESPONSE, val);
                }
            }
            break;
        }
        case RTMP_MSG_AUDIO: {
            if (s->publishing && s->on_audio) {
                s->on_audio(s, msg->payload, msg->length, msg->timestamp);
            }
            break;
        }
        case RTMP_MSG_VIDEO: {
            if (s->publishing && s->on_video) {
                s->on_video(s, msg->payload, msg->length, msg->timestamp);
            }
            break;
        }
        case RTMP_MSG_AMF0_DATA:
        case RTMP_MSG_AMF3_DATA: {
            if (s->publishing && s->on_script) {
                const uint8_t *d = msg->payload;
                size_t l = msg->length;
                if (msg->type_id == RTMP_MSG_AMF3_DATA && l > 0) { d++; l--; }
                s->on_script(s, d, l, msg->timestamp);
            }
            break;
        }
        case RTMP_MSG_AMF0_COMMAND:
        case RTMP_MSG_AMF3_COMMAND: {
            rtmp_message_t cmd = *msg;
            if (msg->type_id == RTMP_MSG_AMF3_COMMAND && cmd.length > 0) {
                cmd.payload++;
                cmd.length--;
            }
            return rtmp_handle_command(s, &cmd);
        }
        default:
            fprintf(stderr, "[rtmp] unhandled msg type %d\n", msg->type_id);
            break;
    }
    return 0;
}

// ── main session loop ───────────────────────────

int rtmp_session_run(rtmp_session_t *s) {
    // per-csid reassembly buffers
    uint8_t *reassembly[64] = {0};
    uint32_t reassembly_got[64] = {0};

    while (s->alive) {
        uint8_t fmt;
        uint32_t csid;
        if (rtmp_read_basic_header(s, &fmt, &csid) < 0) break;

        uint32_t cache_idx = csid < 64 ? csid : 0;
        rtmp_chunk_cache_t *cache = &s->in_cache[cache_idx];

        if (rtmp_read_message_header(s, fmt, csid, cache) < 0) break;

        if (!cache->has_header) continue;

        // allocate reassembly buffer on first chunk
        if (!reassembly[cache_idx]) {
            reassembly[cache_idx] = malloc(cache->length > 0 ? cache->length : 1);
            reassembly_got[cache_idx] = 0;
        } else if (reassembly_got[cache_idx] == 0) {
            // new message, realloc
            reassembly[cache_idx] = realloc(reassembly[cache_idx],
                                             cache->length > 0 ? cache->length : 1);
        }

        // read chunk payload
        uint32_t remaining = cache->length - reassembly_got[cache_idx];
        uint32_t chunk_payload = remaining;
        if (chunk_payload > s->in_chunk_size) chunk_payload = s->in_chunk_size;

        if (chunk_payload > 0) {
            if (sock_read_full(s->fd, reassembly[cache_idx] + reassembly_got[cache_idx],
                               chunk_payload) < 0) break;
            s->in_bytes += chunk_payload;
            reassembly_got[cache_idx] += chunk_payload;
        }

        // ack
        if (s->in_bytes - s->in_bytes_acked >= s->in_window_size / 2) {
            rtmp_send_ack(s);
        }

        // complete message?
        if (reassembly_got[cache_idx] >= cache->length) {
            rtmp_message_t msg;
            msg.timestamp  = cache->timestamp;
            msg.length     = cache->length;
            msg.type_id    = cache->type_id;
            msg.stream_id  = cache->stream_id;
            msg.payload    = reassembly[cache_idx];

            if (rtmp_handle_message(s, &msg) < 0) break;

            reassembly_got[cache_idx] = 0;
        }
    }

    for (int i = 0; i < 64; i++) free(reassembly[i]);
    return s->alive ? 0 : -1;
}
