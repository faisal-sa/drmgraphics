#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

struct dumb_buffer {
    uint32_t handle;
    uint32_t pitch;
    uint64_t size;
    uint32_t fb_id;
    void *map;
};

// Helper function to find a suitable CRTC and encoder
static int find_crtc(int fd, drmModeRes *res, drmModeConnector *conn, uint32_t *crtc_id, uint32_t *connector_id) {
    for (int i = 0; i < conn->count_encoders; i++) {
        drmModeEncoder *encoder = drmModeGetEncoder(fd, conn->encoders[i]);
        if (!encoder) continue;

        for (int j = 0; j < res->count_crtcs; j++) {
            if (encoder->possible_crtcs & (1 << j)) {
                *crtc_id = res->crtcs[j];
                *connector_id = conn->connector_id;
                drmModeFreeEncoder(encoder);
                return 0; // Success
            }
        }
        drmModeFreeEncoder(encoder);
    }
    return -1; // No suitable CRTC found
}

int main() {
    int fd;
    drmModeRes *res;
    drmModeConnector *conn;
    uint32_t conn_id, crtc_id;
    drmModeCrtc *crtc;

    // 1. Open DRM device
    fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        perror("Failed to open DRM device");
        return 1;
    }

    // 2. Get resources
    res = drmModeGetResources(fd);
    if (!res) {
        perror("Failed to get DRM resources");
        close(fd);
        return 1;
    }

    // 3. Find a connected connector
    conn = NULL;
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *temp_conn = drmModeGetConnector(fd, res->connectors[i]);
        if (temp_conn && temp_conn->connection == DRM_MODE_CONNECTED) {
            conn = temp_conn;
            break;
        }
        drmModeFreeConnector(temp_conn);
    }

    if (!conn) {
        fprintf(stderr, "No connected connector found\n");
        drmModeFreeResources(res);
        close(fd);
        return 1;
    }

    // 4. Find a suitable CRTC
    if (find_crtc(fd, res, conn, &crtc_id, &conn_id) != 0) {
        fprintf(stderr, "No suitable CRTC found\n");
        drmModeFreeConnector(conn);
        drmModeFreeResources(res);
        close(fd);
        return 1;
    }
    
    // Get the original CRTC settings to restore them later
    crtc = drmModeGetCrtc(fd, crtc_id);

    // 5. Create a dumb buffer
    struct dumb_buffer buf = {0};
    drmModeModeInfo *mode = &conn->modes[0]; // Use the first available mode
    
    struct drm_mode_create_dumb create_req = {
        .width = mode->hdisplay,
        .height = mode->vdisplay,
        .bpp = 32, // 32 bits per pixel (ARGB8888)
        .flags = 0,
    };
    if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &create_req) < 0) {
        perror("Failed to create dumb buffer");
        // ... cleanup ...
        return 1;
    }
    buf.handle = create_req.handle;
    buf.pitch = create_req.pitch;
    buf.size = create_req.size;

    // 6. Create a framebuffer object
    if (drmModeAddFB(fd, mode->hdisplay, mode->vdisplay, 24, 32, buf.pitch, buf.handle, &buf.fb_id) < 0) {
        perror("Failed to create framebuffer");
        // ... cleanup ...
        return 1;
    }

    // 7. Map the buffer to user memory
    struct drm_mode_map_dumb map_req = { .handle = buf.handle };
    if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &map_req) < 0) {
        perror("Failed to map dumb buffer");
        // ... cleanup ...
        return 1;
    }
    buf.map = mmap(0, buf.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, map_req.offset);
    if (buf.map == MAP_FAILED) {
        perror("mmap failed");
        // ... cleanup ...
        return 1;
    }
    
    // 8. Draw!
    printf("Drawing a gradient to the framebuffer...\n");
    uint32_t *pixels = buf.map;
    for (uint32_t y = 0; y < mode->vdisplay; y++) {
        for (uint32_t x = 0; x < mode->hdisplay; x++) {
            uint8_t red = x * 255 / mode->hdisplay;
            uint8_t green = y * 255 / mode->vdisplay;
            uint8_t blue = 128;
            pixels[y * (buf.pitch / 4) + x] = (red << 16) | (green << 8) | blue;
        }
    }
    
    // 9. Set the mode (this is what displays the framebuffer)
    if (drmModeSetCrtc(fd, crtc_id, buf.fb_id, 0, 0, &conn_id, 1, mode) < 0) {
        perror("Failed to set CRTC");
        // ... cleanup ...
        return 1;
    }
    
    printf("Framebuffer displayed. Press Enter to exit...\n");
    getchar();

    // 10. Cleanup
    munmap(buf.map, buf.size);
    drmModeRmFB(fd, buf.fb_id);
    
    struct drm_mode_destroy_dumb destroy_req = { .handle = buf.handle };
    drmIoctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy_req);

    // Restore original CRTC settings
    drmModeSetCrtc(fd, crtc->crtc_id, crtc->buffer_id, crtc->x, crtc->y, &conn_id, 1, &crtc->mode);
    
    drmModeFreeCrtc(crtc);
    drmModeFreeConnector(conn);
    drmModeFreeResources(res);
    close(fd);

    printf("Cleanup complete.\n");
    return 0;
}
