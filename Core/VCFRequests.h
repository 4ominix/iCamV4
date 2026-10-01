#ifndef VCF_REQUESTS_H
#define VCF_REQUESTS_H
#include <stddef.h>
#include <math.h>

typedef struct { size_t width, height; unsigned format; double time; } VCFRequest;

static inline void VCFRecordRequest(VCFRequest slots[3], size_t width, size_t height,
                                    unsigned format, double now) {
    if (!width || !height || !isfinite(now)) return;
    for (int i = 0; i < 3; i++) {
        if (slots[i].width == width && slots[i].height == height && slots[i].format == format) {
            slots[i].time = now;
            return;
        }
    }
    int chosen = 0;
    for (int i = 0; i < 3; i++) {
        if (!slots[i].width) { chosen = i; break; }
        if (slots[i].time < slots[chosen].time) chosen = i;
    }
    slots[chosen].width = width;
    slots[chosen].height = height;
    slots[chosen].format = format;
    slots[chosen].time = now;
}

static inline int VCFRequestLive(VCFRequest slot, double now) {
    return slot.width && slot.height && isfinite(now) && now >= slot.time && now - slot.time <= 2;
}
#endif
