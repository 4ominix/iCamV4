#include "vcf_rtmp.h"
#include "vcf_flv.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <notify.h>

#define LISTEN_PORT         1935
#define STREAM_DIR          "/var/jb/var/mobile/Library/VCamFree/Streams"
#define STATUS_PATH         "/var/jb/var/mobile/Library/VCamFree/ServerStatus.plist"
#define NOTIF_STATUS        "com.vcamfree.server.status.changed"
#define ROTATE_MS           5000

static volatile bool g_running = true;
static volatile int  g_client_count = 0;

static void write_server_status(bool listening, int clients, int port) {
    FILE *fp = fopen(STATUS_PATH ".tmp", "w");
    if (!fp) return;
    fprintf(fp,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
        "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        "<plist version=\"1.0\">\n<dict>\n"
        "\t<key>listening</key>\n\t<%s/>\n"
        "\t<key>port</key>\n\t<integer>%d</integer>\n"
        "\t<key>clients</key>\n\t<integer>%d</integer>\n"
        "</dict>\n</plist>\n",
        listening ? "true" : "false", port, clients);
    fclose(fp);
    rename(STATUS_PATH ".tmp", STATUS_PATH);
    notify_post(NOTIF_STATUS);
}

// ── RTMP → FLV callbacks ────────────────────────

static void on_audio(rtmp_session_t *s, const uint8_t *data, size_t len, uint32_t ts) {
    vcf_flv_rolling_t *r = (vcf_flv_rolling_t *)s->userdata;
    if (r) vcf_flv_rolling_write(r, 8, data, (uint32_t)len, ts);
}

static void on_video(rtmp_session_t *s, const uint8_t *data, size_t len, uint32_t ts) {
    vcf_flv_rolling_t *r = (vcf_flv_rolling_t *)s->userdata;
    if (r) vcf_flv_rolling_write(r, 9, data, (uint32_t)len, ts);
}

static void on_script(rtmp_session_t *s, const uint8_t *data, size_t len, uint32_t ts) {
    vcf_flv_rolling_t *r = (vcf_flv_rolling_t *)s->userdata;
    if (r) vcf_flv_rolling_write(r, 18, data, (uint32_t)len, ts);
}

// ── client thread ───────────────────────────────

static void *client_thread(void *arg) {
    int fd = *(int *)arg;
    free(arg);

    __sync_add_and_fetch(&g_client_count, 1);
    write_server_status(true, g_client_count, LISTEN_PORT);

    struct sockaddr_in peer;
    socklen_t plen = sizeof(peer);
    getpeername(fd, (struct sockaddr *)&peer, &plen);
    char ip[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof(ip));
    fprintf(stderr, "[stream] client connected: %s:%d\n", ip, ntohs(peer.sin_port));

    rtmp_session_t *sess = rtmp_session_create(fd);

    vcf_flv_rolling_t *roller = vcf_flv_rolling_open(STREAM_DIR, ROTATE_MS);
    sess->userdata = roller;
    sess->on_audio = on_audio;
    sess->on_video = on_video;
    sess->on_script = on_script;

    if (rtmp_handshake(sess) == 0) {
        rtmp_session_run(sess);
    }

    fprintf(stderr, "[stream] client disconnected: %s\n", ip);

    vcf_flv_rolling_close(roller);
    rtmp_session_destroy(sess);

    __sync_sub_and_fetch(&g_client_count, 1);
    write_server_status(true, g_client_count, LISTEN_PORT);

    return NULL;
}

// ── signal handling ─────────────────────────────

static void sig_handler(int sig) {
    (void)sig;
    g_running = false;
}

// ── main ────────────────────────────────────────

int main(int argc, char **argv) {
    (void)argc; (void)argv;

    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, sig_handler);
    signal(SIGINT, sig_handler);

    int port = LISTEN_PORT;
    if (argc > 1) port = atoi(argv[1]);

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { perror("socket"); return 1; }

    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons((uint16_t)port);

    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(srv);
        return 1;
    }

    if (listen(srv, 4) < 0) {
        perror("listen");
        close(srv);
        return 1;
    }

    fprintf(stderr, "[stream] VCFStreamDaemon listening on port %d\n", port);
    write_server_status(true, 0, port);

    while (g_running) {
        struct sockaddr_in cli;
        socklen_t clen = sizeof(cli);
        int cfd = accept(srv, (struct sockaddr *)&cli, &clen);
        if (cfd < 0) {
            if (g_running) perror("accept");
            continue;
        }

        int *fdp = malloc(sizeof(int));
        *fdp = cfd;

        pthread_t tid;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        pthread_create(&tid, &attr, client_thread, fdp);
        pthread_attr_destroy(&attr);
    }

    write_server_status(false, 0, port);
    close(srv);
    fprintf(stderr, "[stream] daemon exiting\n");
    return 0;
}
