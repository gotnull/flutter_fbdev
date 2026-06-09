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
#include <dlfcn.h>
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
#include <time.h>
#include <unistd.h>

#include "flutter_embedder.h"

// Ogg Vorbis decoder (public domain, vendored). Used to decode the bundled
// soundtrack to PCM for ALSA playback. See NOTICE.md.
#define STB_VORBIS_NO_PUSHDATA_API
#include "stb_vorbis.c"

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

// --- audio --------------------------------------------------------------
// Decode a bundled Ogg Vorbis file (stb_vorbis) and play it looped via ALSA.
// libasound is loaded with dlopen at runtime, so the embedder has no build-time
// audio dependency and degrades to silence on a board without ALSA. Driven from
// Dart over the 'flutter_fbdev/audio' channel (play:<path> / stop / volume:<n>).
// ALSA ABI constants (stable): playback stream, S16_LE format, RW interleaved.
#define A_STREAM_PLAYBACK 0
#define A_FORMAT_S16_LE 2
#define A_ACCESS_RW_INTERLEAVED 3

typedef int (*snd_pcm_open_t)(void **, const char *, int, int);
typedef long (*snd_pcm_writei_t)(void *, const void *, unsigned long);
typedef int (*snd_pcm_set_params_t)(void *, int, int, unsigned int,
                                    unsigned int, int, unsigned int);
typedef int (*snd_pcm_recover_t)(void *, int, int);
typedef int (*snd_pcm_prepare_t)(void *);
typedef int (*snd_pcm_close_t)(void *);

static snd_pcm_open_t a_open;
static snd_pcm_writei_t a_writei;
static snd_pcm_set_params_t a_set_params;
static snd_pcm_recover_t a_recover;
static snd_pcm_prepare_t a_prepare;
static snd_pcm_close_t a_close;

static char g_audio_path[1200];
static volatile int g_audio_stop = 0;
static volatile int g_gain_q8 = 128; // 0..256 fixed-point gain (128 ≈ 0.5)
static pthread_t g_audio_th;
static int g_audio_started = 0;

static int load_alsa(void) {
  void *lib = dlopen("libasound.so.2", RTLD_NOW | RTLD_GLOBAL);
  if (!lib) lib = dlopen("libasound.so", RTLD_NOW | RTLD_GLOBAL);
  if (!lib) {
    fprintf(stderr, "[audio] no libasound (%s) - silent\n", dlerror());
    return -1;
  }
  a_open = (snd_pcm_open_t)dlsym(lib, "snd_pcm_open");
  a_writei = (snd_pcm_writei_t)dlsym(lib, "snd_pcm_writei");
  a_set_params = (snd_pcm_set_params_t)dlsym(lib, "snd_pcm_set_params");
  a_recover = (snd_pcm_recover_t)dlsym(lib, "snd_pcm_recover");
  a_prepare = (snd_pcm_prepare_t)dlsym(lib, "snd_pcm_prepare");
  a_close = (snd_pcm_close_t)dlsym(lib, "snd_pcm_close");
  if (!a_open || !a_writei || !a_set_params || !a_recover) {
    fprintf(stderr, "[audio] missing ALSA symbols - silent\n");
    return -1;
  }
  return 0;
}

// Stream-decode + play loop on its own thread. Decoding incrementally (a few
// thousand frames at a time) instead of the whole file up front means playback
// starts immediately and uses little memory; looping is a cheap seek-to-start.
static void *audio_thread(void *arg) {
  (void)arg;
  fprintf(stderr, "[audio] thread start: %s\n", g_audio_path);
  if (load_alsa() != 0) return NULL;
  int err = 0;
  stb_vorbis *v = stb_vorbis_open_filename(g_audio_path, &err, NULL);
  if (!v) {
    fprintf(stderr, "[audio] open failed: %s (err %d)\n", g_audio_path, err);
    return NULL;
  }
  stb_vorbis_info info = stb_vorbis_get_info(v);
  const int channels = info.channels;
  const int rate = (int)info.sample_rate;
  void *h = NULL;
  if (a_open(&h, "default", A_STREAM_PLAYBACK, 0) < 0) {
    fprintf(stderr, "[audio] snd_pcm_open(default) failed - silent\n");
    stb_vorbis_close(v);
    return NULL;
  }
  if (a_set_params(h, A_FORMAT_S16_LE, A_ACCESS_RW_INTERLEAVED,
                   (unsigned)channels, (unsigned)rate, 1, 250000) < 0) {
    fprintf(stderr, "[audio] set_params failed (%dch @ %dHz) - silent\n",
            channels, rate);
    a_close(h);
    stb_vorbis_close(v);
    return NULL;
  }
  fprintf(stderr, "[audio] streaming %dch @ %dHz (looped)\n", channels, rate);
  const int kFrames = 2048;
  short *buf = (short *)malloc((size_t)kFrames * channels * sizeof(short));
  while (!g_audio_stop && buf) {
    int n = stb_vorbis_get_samples_short_interleaved(v, channels, buf,
                                                     kFrames * channels);
    if (n <= 0) {
      stb_vorbis_seek_start(v); // end of track - loop
      continue;
    }
    const int gain = g_gain_q8;
    const int total = n * channels;
    for (int i = 0; i < total; i++) {
      int s = (buf[i] * gain) >> 8;
      buf[i] = (short)(s > 32767 ? 32767 : (s < -32768 ? -32768 : s));
    }
    int off = 0;
    while (off < n && !g_audio_stop) {
      long w = a_writei(h, buf + (size_t)off * channels, (unsigned long)(n - off));
      if (w < 0) {
        a_recover(h, (int)w, 1);
        if (a_prepare) a_prepare(h);
        continue;
      }
      off += (int)w;
    }
  }
  free(buf);
  a_close(h);
  stb_vorbis_close(v);
  return NULL;
}

static void audio_play(const char *rel) {
  if (g_audio_started) return; // one looping track is all the demo needs
  snprintf(g_audio_path, sizeof g_audio_path, "%s/%s", g_bundle, rel);
  g_audio_stop = 0;
  if (pthread_create(&g_audio_th, NULL, audio_thread, NULL) == 0)
    g_audio_started = 1;
}

static void audio_stop(void) {
  if (!g_audio_started) return;
  g_audio_stop = 1;
  pthread_join(g_audio_th, NULL);
  g_audio_started = 0;
}

// Handle one 'flutter_fbdev/audio' message (raw UTF-8 from a StringCodec):
//   play:<path-relative-to-bundle>   stop   volume:<0..100>
static void audio_command(const uint8_t *m, size_t n) {
  char cmd[1300];
  if (n >= sizeof cmd) n = sizeof cmd - 1;
  memcpy(cmd, m, n);
  cmd[n] = 0;
  if (strncmp(cmd, "play:", 5) == 0) {
    audio_play(cmd + 5);
  } else if (strcmp(cmd, "stop") == 0) {
    audio_stop();
  } else if (strncmp(cmd, "volume:", 7) == 0) {
    int pct = atoi(cmd + 7);
    pct = pct < 0 ? 0 : (pct > 100 ? 100 : pct);
    g_gain_q8 = pct * 256 / 100;
  }
}

// Reply EMPTY to every platform message → the framework raises a
// MissingPluginException, which a hardened app bootstrap catches. Without this,
// channels (shared_preferences, etc.) would hang the boot forever. The one
// channel we actually service is 'flutter_fbdev/audio'.
static void on_platform_message(const FlutterPlatformMessage *msg,
                                void *user_data) {
  (void)user_data;
  if (msg->channel && strcmp(msg->channel, "flutter_fbdev/audio") == 0) {
    audio_command(msg->message, msg->message_size);
  }
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

// --- platform task runner -----------------------------------------------
// The engine posts platform-thread work (including delivering Dart→embedder
// platform messages to on_platform_message) to this runner. We pump it on the
// main thread. Without it, incoming messages are queued and never dispatched,
// so an `await channel.send(...)` in Dart hangs forever.
typedef struct {
  FlutterTask task;
  uint64_t target; // engine time (nanos) at which to run
} PendingTask;

static PendingTask g_tasks[512];
static int g_ntasks = 0;
static pthread_mutex_t g_task_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_task_cv = PTHREAD_COND_INITIALIZER;
static pthread_t g_platform_thread;

static bool runs_on_platform(void *user_data) {
  (void)user_data;
  return pthread_equal(pthread_self(), g_platform_thread) != 0;
}

static void post_task(FlutterTask task, uint64_t target_time, void *user_data) {
  (void)user_data;
  pthread_mutex_lock(&g_task_mu);
  if (g_ntasks < (int)(sizeof g_tasks / sizeof g_tasks[0])) {
    g_tasks[g_ntasks].task = task;
    g_tasks[g_ntasks].target = target_time;
    g_ntasks++;
  }
  pthread_cond_signal(&g_task_cv);
  pthread_mutex_unlock(&g_task_mu);
}

// Pump ready tasks forever. Runs on the main (platform) thread.
static void run_task_loop(void) {
  for (;;) {
    FlutterTask ready[512];
    int nready = 0;
    pthread_mutex_lock(&g_task_mu);
    const uint64_t now = FlutterEngineGetCurrentTime();
    uint64_t next = UINT64_MAX;
    for (int i = 0; i < g_ntasks;) {
      if (g_tasks[i].target <= now) {
        ready[nready++] = g_tasks[i].task;
        g_tasks[i] = g_tasks[--g_ntasks]; // swap-remove
      } else {
        if (g_tasks[i].target < next) next = g_tasks[i].target;
        i++;
      }
    }
    if (nready == 0) {
      if (next == UINT64_MAX) {
        pthread_cond_wait(&g_task_cv, &g_task_mu);
      } else {
        // Convert the engine-clock delay to an absolute CLOCK_REALTIME deadline.
        const uint64_t delta = next - now;
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += (time_t)(delta / 1000000000ull);
        ts.tv_nsec += (long)(delta % 1000000000ull);
        if (ts.tv_nsec >= 1000000000L) {
          ts.tv_sec++;
          ts.tv_nsec -= 1000000000L;
        }
        pthread_cond_timedwait(&g_task_cv, &g_task_mu, &ts);
      }
    }
    pthread_mutex_unlock(&g_task_mu);
    for (int i = 0; i < nready; i++) FlutterEngineRunTask(g_engine, &ready[i]);
  }
}

int main(int argc, char **argv) {
  const char *bundle = argc > 1 ? argv[1] : ".";
  g_bundle = bundle;
  g_platform_thread = pthread_self();
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

  // Pump platform-thread work (incl. incoming platform messages) on main.
  FlutterTaskRunnerDescription platform_rd = {
      .struct_size = sizeof(FlutterTaskRunnerDescription),
      .user_data = NULL,
      .runs_task_on_current_thread_callback = runs_on_platform,
      .post_task_callback = post_task,
      .identifier = 1,
  };
  FlutterCustomTaskRunners task_runners = {
      .struct_size = sizeof(FlutterCustomTaskRunners),
      .platform_task_runner = &platform_rd,
  };
  args.custom_task_runners = &task_runners;

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

  run_task_loop(); // pump the platform task runner on the main thread
  return 0;
}
