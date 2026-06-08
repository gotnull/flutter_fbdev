// flutter_fbdev_embedder.c - a tiny Flutter embedder that renders to the Linux
// framebuffer (/dev/fb0) with the engine's SOFTWARE renderer, and forwards raw
// gamepad/evdev input to Dart over the 'flutter_fbdev/input' platform channel.
//
// For no-DRM Allwinner/Mali-fbdev handhelds (e.g. the Anbernic RG34XXSP) where
// flutter-pi (DRM/KMS-only) cannot run - there is no /dev/dri, no libdrm/libgbm.
// We need none of that: just the framebuffer everything else already uses.
//
// Build with native/build_embedder.sh; run as:  flutter_fbdev <bundle-dir>
// (the dir holding app.so, icudtl.dat, the assets, and libflutter_engine.so).
//
// Part of the flutter_fbdev package: https://github.com/gotnull/flutter_fbdev

#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "flutter_embedder.h"

static uint8_t *g_fb = NULL; // mmap'd framebuffer
static struct fb_var_screeninfo g_vinfo;
static struct fb_fix_screeninfo g_finfo;
static size_t g_w = 0, g_h = 0; // visible pixels we present
static int g_fbfd = -1;
static FlutterEngine g_engine = NULL;
static const char *g_bundle = "."; // bundle dir (also holds run/input logs)

// The engine's "native 32-bit RGBA" software buffer is actually Skia kN32, which
// on little-endian is BGRA byte order: memory is B,G,R,A. Repack each pixel into
// the framebuffer's own channel layout (from its bitfield offsets, so this is
// correct for any fb format) and copy in.
static bool present(void *user_data, const void *allocation, size_t row_bytes,
                    size_t height) {
  (void)user_data;
  const uint32_t ro = g_vinfo.red.offset, go = g_vinfo.green.offset,
                 bo = g_vinfo.blue.offset, to = g_vinfo.transp.offset;
  const size_t rows = height < g_h ? height : g_h;
  const size_t cols = (row_bytes / 4) < g_w ? (row_bytes / 4) : g_w;
  for (size_t y = 0; y < rows; y++) {
    const uint8_t *s = (const uint8_t *)allocation + y * row_bytes;
    uint32_t *d = (uint32_t *)(g_fb + y * g_finfo.line_length);
    for (size_t x = 0; x < cols; x++) {
      const uint32_t b = s[0], gg = s[1], r = s[2], a = s[3];
      d[x] = (r << ro) | (gg << go) | (b << bo) | (a << to);
      s += 4;
    }
  }
  // Make sure the buffer we just wrote (offset 0) is the one being scanned out -
  // many panels are double-buffered (yres_virtual = 2×yres) and may be panned.
  if (g_fbfd >= 0) {
    g_vinfo.xoffset = 0;
    g_vinfo.yoffset = 0;
    ioctl(g_fbfd, FBIOPAN_DISPLAY, &g_vinfo);
  }
  return true;
}

// Route engine + Dart print() logs to stderr (so a launcher can capture them).
static void on_log(const char *tag, const char *message, void *user_data) {
  (void)user_data;
  fprintf(stderr, "[dart:%s] %s\n", tag ? tag : "", message ? message : "");
  fflush(stderr);
}

// Reply EMPTY to every platform message → the framework raises a
// MissingPluginException, which a hardened app bootstrap catches. Without this,
// channels (shared_preferences, etc.) would hang the boot forever.
static void on_platform_message(const FlutterPlatformMessage *msg,
                                void *user_data) {
  (void)user_data;
  if (g_engine && msg->response_handle) {
    FlutterEngineSendPlatformMessageResponse(g_engine, msg->response_handle,
                                             NULL, 0);
  }
}

// Forward every raw input event (face keys + d-pad hat + sticks) to Dart over the
// 'flutter_fbdev/input' channel as "type:code:value". Dart owns the mapping (so a
// remap needs no embedder rebuild) - the embedder stays generic and reusable.
static void send_raw(const char *type, uint16_t code, int value) {
  if (!g_engine) return;
  char buf[64];
  int len = snprintf(buf, sizeof buf, "%s:%u:%d", type, code, value);
  if (len <= 0) return;
  FlutterPlatformMessage msg = {
      .struct_size = sizeof(FlutterPlatformMessage),
      .channel = "flutter_fbdev/input",
      .message = (const uint8_t *)buf,
      .message_size = (size_t)len,
      .response_handle = NULL,
  };
  FlutterEngineSendPlatformMessage(g_engine, &msg);
}

static void *input_thread(void *arg) {
  (void)arg;
  struct pollfd pfds[8];
  int n = 0;
  for (int i = 0; i < 8 && n < 8; i++) {
    char path[32];
    snprintf(path, sizeof path, "/dev/input/event%d", i);
    int fd = open(path, O_RDONLY);
    if (fd >= 0) {
      pfds[n].fd = fd;
      pfds[n].events = POLLIN;
      n++;
      fprintf(stderr, "[input] watching %s\n", path);
    }
  }
  fflush(stderr);
  struct input_event ev;
  while (1) {
    if (poll(pfds, n, -1) <= 0) continue;
    for (int i = 0; i < n; i++) {
      if (!(pfds[i].revents & POLLIN)) continue;
      if (read(pfds[i].fd, &ev, sizeof ev) != (ssize_t)sizeof ev) continue;
      if (ev.type != EV_KEY && ev.type != EV_ABS) continue;
      const char *t = (ev.type == EV_KEY) ? "key" : "abs";
      fprintf(stderr, "[input] %s code=%u value=%d\n", t, ev.code, ev.value);
      fflush(stderr);
      send_raw(t, ev.code, ev.value);
      // Hard quit stays in the embedder so it works even if Dart is wedged.
      if (ev.type == EV_KEY && ev.value == 1 &&
          (ev.code == KEY_POWER || ev.code == KEY_VOLUMEUP ||
           ev.code == KEY_VOLUMEDOWN)) {
        fprintf(stderr, "[input] quit key %u - exiting\n", ev.code);
        if (g_fb != MAP_FAILED && g_fb)
          memset(g_fb, 0, (size_t)g_finfo.line_length * g_vinfo.yres_virtual);
        _exit(0);
      }
    }
  }
  return NULL;
}

int main(int argc, char **argv) {
  const char *bundle = argc > 1 ? argv[1] : ".";
  g_bundle = bundle;
  setvbuf(stderr, NULL, _IOLBF, 0);

  // --- framebuffer ---
  int fbfd = open("/dev/fb0", O_RDWR);
  if (fbfd < 0) {
    perror("open /dev/fb0");
    return 1;
  }
  g_fbfd = fbfd;
  ioctl(fbfd, FBIOGET_FSCREENINFO, &g_finfo);
  ioctl(fbfd, FBIOGET_VSCREENINFO, &g_vinfo);
  g_w = g_vinfo.xres;
  g_h = g_vinfo.yres;
  fprintf(stderr, "[fb] %zux%zu bpp=%u stride=%u  R@%u G@%u B@%u A@%u\n", g_w,
          g_h, g_vinfo.bits_per_pixel, g_finfo.line_length, g_vinfo.red.offset,
          g_vinfo.green.offset, g_vinfo.blue.offset, g_vinfo.transp.offset);
  size_t fbsize = (size_t)g_finfo.line_length * g_vinfo.yres_virtual;
  g_fb = mmap(NULL, fbsize, PROT_READ | PROT_WRITE, MAP_SHARED, fbfd, 0);
  if (g_fb == MAP_FAILED) {
    perror("mmap fb");
    return 1;
  }
  memset(g_fb, 0, fbsize);

  // --- software renderer ---
  FlutterRendererConfig rc = {0};
  rc.type = kSoftware;
  rc.software.struct_size = sizeof(FlutterSoftwareRendererConfig);
  rc.software.surface_present_callback = present;

  // --- AOT data (app.so) ---
  char app_so[1024], icu[1024];
  snprintf(app_so, sizeof app_so, "%s/app.so", bundle);
  snprintf(icu, sizeof icu, "%s/icudtl.dat", bundle);
  FlutterEngineAOTData aot = NULL;
  FlutterEngineAOTDataSource src = {
      .type = kFlutterEngineAOTDataSourceTypeElfPath, .elf_path = app_so};
  if (FlutterEngineCreateAOTData(&src, &aot) != kSuccess) {
    fprintf(stderr, "FATAL: could not load AOT data from %s\n", app_so);
    return 1;
  }

  // --- project args ---
  const char *cmd_argv[] = {"flutter_fbdev"};
  FlutterProjectArgs args = {0};
  args.struct_size = sizeof(FlutterProjectArgs);
  args.assets_path = bundle;
  args.icu_data_path = icu;
  args.command_line_argc = 1;
  args.command_line_argv = cmd_argv;
  args.aot_data = aot;
  args.platform_message_callback = on_platform_message;
  args.log_message_callback = on_log;
  args.log_tag = "flutter";

  // --- run ---
  FlutterEngineResult res =
      FlutterEngineRun(FLUTTER_ENGINE_VERSION, &rc, &args, NULL, &g_engine);
  if (res != kSuccess) {
    fprintf(stderr, "FATAL: FlutterEngineRun failed (%d)\n", res);
    return 1;
  }
  fprintf(stderr, "[engine] running\n");

  // --- window metrics (kicks the first frame) ---
  FlutterWindowMetricsEvent wm = {0};
  wm.struct_size = sizeof(FlutterWindowMetricsEvent);
  wm.width = g_w;
  wm.height = g_h;
  wm.pixel_ratio = 1.0;
  FlutterEngineSendWindowMetricsEvent(g_engine, &wm);
  fprintf(stderr, "[engine] sent metrics %zux%zu - first frame requested\n", g_w,
          g_h);

  pthread_t input;
  pthread_create(&input, NULL, input_thread, NULL);

  for (;;) pause();
  return 0;
}
