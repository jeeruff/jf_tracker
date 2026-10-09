// jf_touch — пальцы трекпада для jf_tracker (9 окт).
//
// Запускает пользователь (не трекер): ./jf_touch  (или жестом / клавишей BTT).
// Пока зажаты Control+Option и на трекпаде есть пальцы, шлёт их в REAPER
// через веб-интерфейс (порт 8080): ExtState jf_tracker/touch =
//   "<seq>:<id>,<x>,<y>:<id>,<x>,<y>…"   x, y — 0..1 (y = 1 — верх трекпада)
// не чаще 60 раз в секунду; отпустил клавиши или пальцы — одно "<seq>:" и
// тишина. Трекер (жест Ctrl+Option) двигает пальцами фейдеры: справа налево
// — выделенные каналы, иначе соседи канала под первым пальцем.
//
// MultitouchSupport — закрытый фреймворк Apple (так же работают BTT,
// Multitouch.app): подгружается через dlopen, линковать не нужно.
// Сборка:  clang -O2 -o jf_touch jf_touch.c -framework CoreFoundation -framework ApplicationServices
// Порт:    ./jf_touch 8080   (по умолчанию 8080)

#include <CoreFoundation/CoreFoundation.h>
#include <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>

typedef struct { float x, y; } mtPoint;
typedef struct { mtPoint pos, vel; } mtReadout;
typedef struct {
  int frame;
  double timestamp;
  int identifier, state, foo3, foo4;
  mtReadout normalized;
  float size;
  int zero1;
  float angle, majorAxis, minorAxis;
  mtReadout mm;
  int zero2[2];
  float unk2;
} Finger;

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, Finger *, int, double, int);
static CFMutableArrayRef (*pMTDeviceCreateList)(void);
static void (*pMTRegisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
static void (*pMTDeviceStart)(MTDeviceRef, int);

static int port = 8080;
static unsigned seq = 0;
static double last_send = 0;
static int was_active = 0;

static double now_s(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

// GET http://127.0.0.1:port/_/SET/EXTSTATE/jf_tracker/touch/<val> — ответ не ждём
static void send_state(const char *val) {
  int s = socket(AF_INET, SOCK_STREAM, 0);
  if (s < 0) return;
  struct sockaddr_in a; memset(&a, 0, sizeof a);
  a.sin_family = AF_INET; a.sin_port = htons(port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  struct timeval tv = { 0, 50000 };
  setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
  if (connect(s, (struct sockaddr *)&a, sizeof a) == 0) {
    char req[1024];
    int n = snprintf(req, sizeof req, "GET /_/SET/EXTSTATE/jf_tracker/touch/%s HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n", val);
    if (n > 0 && n < (int)sizeof req) { ssize_t w = write(s, req, (size_t)n); (void)w; }
    char buf[256]; ssize_t r = read(s, buf, sizeof buf); (void)r;
  }
  close(s);
}

static int on_frame(MTDeviceRef dev, Finger *f, int n, double ts, int frame) {
  (void)dev; (void)ts; (void)frame;
  CGEventFlags fl = CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  int mods = (fl & kCGEventFlagMaskControl) && (fl & kCGEventFlagMaskAlternate);
  int active = mods && n > 0;
  double t = now_s();
  if (active) {
    if (t - last_send < 1.0 / 60) return 0;
    last_send = t;
    char val[900]; int p = snprintf(val, sizeof val, "%u", ++seq);
    for (int i = 0; i < n && i < 11 && p < (int)sizeof val - 40; i++) {
      // : и , в пути URL без кодирования
      p += snprintf(val + p, sizeof val - p, ":%d,%.4f,%.4f", f[i].identifier, f[i].normalized.pos.x, f[i].normalized.pos.y);
    }
    send_state(val);
    was_active = 1;
  } else if (was_active) {
    char val[32]; snprintf(val, sizeof val, "%u:", ++seq);
    send_state(val);
    was_active = 0;
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc > 1) port = atoi(argv[1]);
  void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
  if (!h) { fprintf(stderr, "jf_touch: MultitouchSupport not found\n"); return 1; }
  pMTDeviceCreateList = dlsym(h, "MTDeviceCreateList");
  pMTRegisterContactFrameCallback = dlsym(h, "MTRegisterContactFrameCallback");
  pMTDeviceStart = dlsym(h, "MTDeviceStart");
  if (!pMTDeviceCreateList || !pMTRegisterContactFrameCallback || !pMTDeviceStart) { fprintf(stderr, "jf_touch: MultitouchSupport API missing\n"); return 1; }
  CFMutableArrayRef list = pMTDeviceCreateList();
  CFIndex nd = list ? CFArrayGetCount(list) : 0;
  for (CFIndex i = 0; i < nd; i++) {
    MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
    pMTRegisterContactFrameCallback(d, on_frame);
    pMTDeviceStart(d, 0);
  }
  fprintf(stderr, "jf_touch: %ld trackpad(s), REAPER port %d; hold Control+Option and touch. Ctrl+C quits.\n", (long)nd, port);
  if (nd == 0) return 1;
  CFRunLoopRun();
  return 0;
}
