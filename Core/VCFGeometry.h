#ifndef VCF_GEOMETRY_H
#define VCF_GEOMETRY_H
#include <math.h>

typedef struct { double a, b, c, d, tx, ty; } VCFMatrix;

static inline VCFMatrix VCFGeometry(double sw, double sh, double dw, double dh,
                                    int rotation, int mirror, int fill,
                                    double zoom, double x, double y) {
    VCFMatrix m = {0, 0, 0, 0, 0, 0};
    if (!isfinite(sw) || !isfinite(sh) || !isfinite(dw) || !isfinite(dh) ||
        sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) return m;
    if (!isfinite(zoom)) zoom = 1;
    if (!isfinite(x)) x = 0;
    if (!isfinite(y)) y = 0;
    zoom = fmin(8, fmax(.25, zoom));
    x = fmin(2, fmax(-2, x));
    y = fmin(2, fmax(-2, y));

    int quadrant = ((rotation / 90) % 4 + 4) % 4;
    double rw = (quadrant % 2) ? sh : sw;
    double rh = (quadrant % 2) ? sw : sh;
    double scale = (fill ? fmax(dw / rw, dh / rh) : fmin(dw / rw, dh / rh)) * zoom;

    double cosine = quadrant == 0 ? 1 : quadrant == 2 ? -1 : 0;
    double sine = quadrant == 1 ? -1 : quadrant == 3 ? 1 : 0;
    double flip = mirror ? -1 : 1;

    m.a = cosine * scale * flip;
    m.b = sine * scale;
    m.c = -sine * scale * flip;
    m.d = cosine * scale;
    m.tx = dw / 2 + x * dw / 2 - m.a * sw / 2 - m.c * sh / 2;
    m.ty = dh / 2 - y * dh / 2 - m.b * sw / 2 - m.d * sh / 2;
    return m;
}
#endif
