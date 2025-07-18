#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <signal.h>
#include <errno.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

struct dumb_buffer {
    uint32_t handle;
    uint32_t pitch;
    uint64_t size;
    uint32_t fb_id;
    void *map;
};

// Global flag to handle Ctrl+C
static int running = 1;

void sigint_handler(int arg) {
    running = 0;
}

// Helper to find CRTC/Connector (same as before)
static int find_crtc(int fd, drmModeRes *res, drmModeConnector *conn, uint32_t *crtc_id, uint32_t *connector_id) {
    for (int i = 0; i < conn->count_encoders; i++) {
        drmModeEncoder *encoder = drmModeGetEncoder(fd, conn->encoders[i]);
        if (!encoder) continue;
        for (int j = 0; j < res->count_crtcs; j++) {
            if (encoder->possible_crtcs & (1 << j)) {
                *crtc_id = res->crtcs[j]; *connector_id = conn->connector_id;
                drmModeFreeEncoder(encoder); return 0;
            }
        }
        drmModeFreeEncoder(encoder);
    }
    return -1;
}

// Helper to create a dumb buffer and framebuffer
static int create_fb(int fd, struct dumb_buffer *buf, int width, int height) {
    struct drm_mode_create_dumb create_req = { .width = width, .height = height, .bpp = 32, .flags = 0 };
    if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &create_req) < 0) return -1;
    buf->handle = create_req.handle; buf->pitch = create_req.pitch; buf->size = create_req.size;
    if (drmModeAddFB(fd, width, height, 24, 32, buf->pitch, buf->handle, &buf->fb_id) < 0) return -1;
    struct drm_mode_map_dumb map_req = { .handle = buf->handle };
    if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &map_req) < 0) return -1;
    buf->map = mmap(0, buf->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, map_req.offset);
    if (buf->map == MAP_FAILED) return -1;
    return 0;
}

// Helper to draw a filled rectangle
static void draw_rect(struct dumb_buffer *buf, int width, int x_pos, int y_pos, int w, int h, uint32_t color) {
    uint32_t *pixels = buf->map;
    for (int y = y_pos; y < y_pos + h; y++) {
        for (int x = x_pos; x < x_pos + w; x++) {
            if (x < 0 || x >= width || y < 0 || y >= buf->pitch * 8 / 32 / 4) continue; // Boundary check
            pixels[y * (buf->pitch / 4) + x] = color;
        }
    }
}


int main() {
    int fd;
    drmModeRes *res;
    drmModeConnector *conn;
    uint32_t conn_id, crtc_id;
    drmModeCrtc *saved_crtc;

    signal(SIGINT, sigint_handler);

    fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    res = drmModeGetResources(fd);
    
    conn = NULL;
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *temp_conn = drmModeGetConnector(fd, res->connectors[i]);
        if (temp_conn && temp_conn->connection == DRM_MODE_CONNECTED) { conn = temp_conn; break; }
        drmModeFreeConnector(temp_conn);
    }
    if (!conn) { fprintf(stderr, "No connected connector\n"); return 1; }

    if (find_crtc(fd, res, conn, &crtc_id, &conn_id) != 0) {
        fprintf(stderr, "No suitable CRTC\n"); return 1;
    }
    
    saved_crtc = drmModeGetCrtc(fd, crtc_id);
    drmModeModeInfo *mode = &conn->modes[0];

    // Create two buffers for double buffering
    struct dumb_buffer bufs[2];
    if (create_fb(fd, &bufs[0], mode->hdisplay, mode->vdisplay) != 0) return 1;
    if (create_fb(fd, &bufs[1], mode->hdisplay, mode->vdisplay) != 0) return 1;

    // Set the first buffer
    drmModeSetCrtc(fd, crtc_id, bufs[0].fb_id, 0, 0, &conn_id, 1, mode);

    // Animation variables
    int current_buf = 0;
    float rect_x = 50.0f, rect_y = 50.0f;
    float vx = 3.5f, vy = 3.5f;
    int rect_w = 100, rect_h = 100;

    drmEventContext ev = { .version = DRM_EVENT_CONTEXT_VERSION, .page_flip_handler = NULL };

    printf("Starting animation... Press Ctrl+C to exit.\n");

    while(running) {
        struct dumb_buffer *b = &bufs[current_buf];

        // 1. Draw to the back buffer
        memset(b->map, 0, b->size); // Clear to black
        draw_rect(b, mode->hdisplay, (int)rect_x, (int)rect_y, rect_w, rect_h, 0x00FF00FF); // Magenta

        // 2. Schedule page flip
        if (drmModePageFlip(fd, crtc_id, b->fb_id, DRM_MODE_PAGE_FLIP_EVENT, ¤t_buf) < 0) {
            perror("Page flip failed");
            break;
        }

        // 3. Wait for the flip to complete
        // A real app would use select/poll, this is a simplified wait
        while (drmHandleEvent(fd, &ev) != 0) {
             if (errno != EAGAIN) {
                 perror("drmHandleEvent failed");
                 running = 0;
                 break;
             }
        }

        // 4. Update animation logic
        rect_x += vx;
        rect_y += vy;
        if (rect_x + rect_w > mode->hdisplay || rect_x < 0) vx = -vx;
        if (rect_y + rect_h > mode->vdisplay || rect_y < 0) vy = -vy;

        // 5. Swap buffers
        current_buf = 1 - current_buf;
    }

    // --- Cleanup ---
    printf("\nCleaning up...\n");
    drmModeSetCrtc(fd, saved_crtc->crtc_id, saved_crtc->buffer_id, saved_crtc->x, saved_crtc->y, &conn_id, 1, &saved_crtc->mode);
    drmModeFreeCrtc(saved_crtc);

    for (int i = 0; i < 2; i++) {
        munmap(bufs[i].map, bufs[i].size);
        drmModeRmFB(fd, bufs[i].fb_id);
        struct drm_mode_destroy_dumb destroy_req = { .handle = bufs[i].handle };
        drmIoctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy_req);
    }
    
    drmModeFreeConnector(conn);
    drmModeFreeResources(res);
    close(fd);
    printf("Cleanup complete.\n");
    return 0;
}
