/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * device.c - printer connection and status for rastertoufr2lt.
 *
 * The data stream is carried by Apple's /usr/bin/nc, fed through a pipe: macOS
 * "Local Network" privacy blocks LAN connections from non-Apple binaries running
 * in the background (EHOSTUNREACH), while Apple's own tools are allowed. Bonjour
 * lookups go through mDNSResponder and status comes from /usr/bin/snmpget.
 * UFR2LT_TRANSPORT=direct connects in-process instead.
 */
#include "device.h"

#include <arpa/inet.h>
#include <dns_sd.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

#define NC      "/usr/bin/nc"
#define SNMPGET "/usr/bin/snmpget"

/* ------------------------------------------------------------------------ */
/* Child processes                                                           */
/* ------------------------------------------------------------------------ */

static pid_t spawn(char *const argv[], int stdin_fd, int stdout_fd, int stderr_fd) {
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  if (stdin_fd >= 0) posix_spawn_file_actions_adddup2(&fa, stdin_fd, 0);
  else posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
  if (stdout_fd >= 0) posix_spawn_file_actions_adddup2(&fa, stdout_fd, 1);
  else posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
  if (stderr_fd >= 0) posix_spawn_file_actions_adddup2(&fa, stderr_fd, 2);
  else posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
  posix_spawnattr_t attr;                         /* inherit only fds 0-2 */
  posix_spawnattr_init(&attr);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
  pid_t pid;
  int rc = posix_spawn(&pid, argv[0], &fa, &attr, argv, environ);
  posix_spawnattr_destroy(&attr);
  posix_spawn_file_actions_destroy(&fa);
  return rc ? -1 : pid;
}

/* Seconds for timeouts: monotonic, so a clock change can't end or stretch a wait. */
static time_t mono(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec;
}

/* The job's parent (ippeveprinter). Once it is gone nobody waits for this job:
 * stop instead of holding the printer's only data session for half an hour. */
static pid_t parent_pid;

static int orphaned(void) { return parent_pid && getppid() != parent_pid; }

/* waitpid with timeout; when it expires the child gets SIGTERM, then SIGKILL, and
 * is always reaped. Returns exit status or -1. */
static int wait_child(pid_t pid, int timeout_s) {
  int status;
  for (long i = 0; i < (long)timeout_s * 10 && !orphaned(); i++) {
    pid_t r = waitpid(pid, &status, WNOHANG);
    if (r == pid) return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    if (r < 0 && errno != EINTR) return -1;
    usleep(100000);
  }
  kill(pid, SIGTERM);
  for (int i = 0; i < 20; i++) {
    if (waitpid(pid, &status, WNOHANG) == pid) return -1;
    usleep(100000);
  }
  kill(pid, SIGKILL);
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
    ;
  return -1;
}

/* Run a command and capture its stdout. Returns its exit status or -1. The read
 * has the same deadline: a child that hangs must not hang its caller. */
static int run_capture(char *const argv[], char *buf, size_t buflen, int timeout_s) {
  int p[2];
  buf[0] = '\0';
  if (pipe(p)) return -1;
  fcntl(p[0], F_SETFD, FD_CLOEXEC);
  fcntl(p[1], F_SETFD, FD_CLOEXEC);
  pid_t pid = spawn(argv, -1, p[1], -1);
  close(p[1]);
  size_t n = 0;
  time_t end = mono() + timeout_s;
  while (pid > 0 && n + 1 < buflen) {
    long left = (long)(end - mono());
    struct pollfd pf = { p[0], POLLIN, 0 };
    int ready = left > 0 ? poll(&pf, 1, (int)left * 1000) : 0;
    if (ready < 0 && errno == EINTR) continue;
    if (ready <= 0) break;
    ssize_t r = read(p[0], buf + n, buflen - 1 - n);
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) break;
    n += (size_t)r;
  }
  buf[n] = '\0';
  close(p[0]);
  long left = (long)(end - mono());
  return pid > 0 ? wait_child(pid, left > 1 ? (int)left : 1) : -1;
}

/* ------------------------------------------------------------------------ */
/* Name resolution                                                           */
/* ------------------------------------------------------------------------ */

typedef struct { char host[256]; uint16_t port; int done; } resolve_t;

static void DNSSD_API resolve_cb(DNSServiceRef sd, DNSServiceFlags flags, uint32_t ifi,
                                 DNSServiceErrorType err, const char *fullname, const char *target,
                                 uint16_t port, uint16_t txtlen, const unsigned char *txt, void *ctx) {
  resolve_t *r = ctx;
  if (err == kDNSServiceErr_NoError) {
    snprintf(r->host, sizeof(r->host), "%s", target);
    r->port = ntohs(port);
  }
  r->done = 1;
}

/* Resolve a _pdl-datastream._tcp (raw port 9100) Bonjour service instance. */
static int dnssd_resolve(const char *name, char *host, size_t hostlen, int *port) {
  DNSServiceRef sd;
  resolve_t r = {0};
  if (DNSServiceResolve(&sd, 0, kDNSServiceInterfaceIndexAny, name, "_pdl-datastream._tcp", "local.",
                        resolve_cb, &r) != kDNSServiceErr_NoError)
    return -1;
  struct pollfd p = { DNSServiceRefSockFD(sd), POLLIN, 0 };
  for (int tries = 0; !r.done && tries < 2; tries++)
    if (poll(&p, 1, 3000) > 0) DNSServiceProcessResult(sd);
  DNSServiceRefDeallocate(sd);
  if (!r.host[0]) return -1;
  snprintf(host, hostlen, "%s", r.host);
  *port = r.port ? r.port : 9100;
  return 0;
}

typedef struct { char names[16][256]; int n; } browse_t;

static void DNSSD_API browse_cb(DNSServiceRef sd, DNSServiceFlags flags, uint32_t ifi, DNSServiceErrorType err,
                                const char *name, const char *type, const char *domain, void *ctx) {
  browse_t *b = ctx;
  if (err != kDNSServiceErr_NoError || !(flags & kDNSServiceFlagsAdd) || b->n >= 16) return;
  for (int i = 0; i < b->n; i++)
    if (!strcmp(b->names[i], name)) return;
  snprintf(b->names[b->n++], sizeof(b->names[0]), "%s", name);
}

static int resolve_ipv4(const char *host, char *ip, size_t iplen);
static int snmp_descr_has(const char *ip, const char *text);

/* The "dnssd://" + "*" wildcard: the first MF4700-series printer that advertises
 * a raw port here (other printers are skipped by their SNMP description). */
static int dnssd_browse(char *host, size_t hostlen, int *port) {
  DNSServiceRef sd;
  browse_t b = {0};
  if (DNSServiceBrowse(&sd, 0, kDNSServiceInterfaceIndexAny, "_pdl-datastream._tcp", "local.",
                       browse_cb, &b) != kDNSServiceErr_NoError)
    return -1;
  struct pollfd p = { DNSServiceRefSockFD(sd), POLLIN, 0 };
  for (int i = 0; i < 6; i++)                     /* answers trickle in for a second or two */
    if (poll(&p, 1, 400) > 0) DNSServiceProcessResult(sd);
  DNSServiceRefDeallocate(sd);
  for (int i = 0; i < b.n; i++) {
    char h[256], ip[64];
    int pt;
    if (dnssd_resolve(b.names[i], h, sizeof(h), &pt) || resolve_ipv4(h, ip, sizeof(ip))) continue;
    if (snmp_descr_has(ip, "MF47")) {
      snprintf(host, hostlen, "%s", h);
      *port = pt;
      return 0;
    }
  }
  return -1;
}

static int resolve_ipv4(const char *host, char *ip, size_t iplen) {
  struct addrinfo hints = {0}, *res;
  hints.ai_family = AF_INET;                      /* the printer only speaks IPv4; avoids AAAA waits */
  hints.ai_socktype = SOCK_STREAM;
  if (getaddrinfo(host, NULL, &hints, &res)) return -1;
  int rc = getnameinfo(res->ai_addr, res->ai_addrlen, ip, (socklen_t)iplen, NULL, 0, NI_NUMERICHOST);
  freeaddrinfo(res);
  return rc ? -1 : 0;
}

/* One URI (dnssd://Service%20Name, the dnssd wildcard for any MF4700-series
 * printer, socket://host[:port], host[:port]) -> host and port. */
static int uri_host(const char *u, char *host, size_t hostlen, int *port, int quiet) {
  *port = 9100;
  if (!strcmp(u, "dnssd://*")) {
    if (dnssd_browse(host, hostlen, port)) {
      if (!quiet) fprintf(stderr, "INFO: no MF4700-series printer found via Bonjour\n");
      return -1;
    }
    return 0;
  }
  if (!strncmp(u, "dnssd://", 8)) {
    char name[256];
    snprintf(name, sizeof(name), "%s", u + 8);
    for (char *s = name, *d = name; ; s++) {        /* percent-decode service names */
      if (*s == '%' && s[1] && s[2]) { char hx[3] = { s[1], s[2], 0 }; *d++ = (char)strtol(hx, NULL, 16); s += 2; }
      else if (!(*d++ = *s)) break;
    }
    char *slash = strchr(name, '/');
    if (slash) *slash = '\0';
    if (dnssd_resolve(name, host, hostlen, port)) {
      if (!quiet) fprintf(stderr, "INFO: Bonjour lookup of \"%s\" failed\n", name);
      return -1;
    }
    return 0;
  }
  snprintf(host, hostlen, "%s", strncmp(u, "socket://", 9) ? u : u + 9);
  char *slash = strchr(host, '/');
  if (slash) *slash = '\0';
  char *colon = strrchr(host, ':');
  if (colon) { *port = atoi(colon + 1); *colon = '\0'; }
  return 0;
}

/* ------------------------------------------------------------------------ */
/* Transport                                                                 */
/* ------------------------------------------------------------------------ */

static pid_t nc_pid = -1;
static int nc_err = -1;                           /* nc's stderr, for its error messages */

static int use_nc(void) {
  const char *t = getenv("UFR2LT_TRANSPORT");
  return !(t && !strcmp(t, "direct")) && access(NC, X_OK) == 0;
}

/* Report what nc said (minus its "succeeded" banner) as INFO lines. */
static void nc_report(const char *text) {
  char copy[1024];
  snprintf(copy, sizeof(copy), "%s", text);
  for (char *save = NULL, *l = strtok_r(copy, "\n", &save); l; l = strtok_r(NULL, "\n", &save))
    if (*l && !strstr(l, "succeeded")) fprintf(stderr, "INFO: %s\n", l);
}

/* Start nc and return the write end of its stdin once nc reports the connection
 * (-v prints "Connection to ... succeeded!"). One connection per job: the
 * printer's raw port takes a single session and may refuse one that arrives
 * right after another closes. */
static int nc_open(const char *ip, int port) {
  int in[2], err[2];
  if (pipe(in)) return -1;
  if (pipe(err)) { close(in[0]); close(in[1]); return -1; }
  /* close-on-exec, or other children would hold the write end and nc would never see EOF */
  for (int i = 0; i < 2; i++) { fcntl(in[i], F_SETFD, FD_CLOEXEC); fcntl(err[i], F_SETFD, FD_CLOEXEC); }
  char ps[16];
  snprintf(ps, sizeof(ps), "%d", port);
  /* No -w: it silently drops the connection whenever the printer stops reading for a
   * while (paper jam). macOS nc half-closes on our EOF and exits when the printer hangs up. */
  char *argv[] = { NC, "-v", "-G", "10", (char *)ip, ps, NULL };
  nc_pid = spawn(argv, in[0], -1, err[1]);
  close(in[0]);
  close(err[1]);
  if (nc_pid < 0) { close(in[1]); close(err[0]); return -1; }
  char buf[1024];
  size_t n = 0;
  int connected = 0;
  time_t end = mono() + 15;
  while (!connected && mono() <= end) {
    struct pollfd p = { err[0], POLLIN, 0 };
    if (poll(&p, 1, 500) <= 0) continue;
    ssize_t r = read(err[0], buf + n, sizeof(buf) - 1 - n);
    if (r <= 0) break;                            /* nc gave up */
    n += (size_t)r;
    buf[n] = '\0';
    connected = strstr(buf, "succeeded") != NULL;
  }
  buf[n] = '\0';
  if (!connected) {
    nc_report(buf);
    close(in[1]);
    close(err[0]);
    wait_child(nc_pid, 5);
    nc_pid = -1;
    return -1;
  }
  nc_err = err[0];
  return in[1];
}

static int tcp_connect(const char *ip, int port, int timeout_ms) {
  struct sockaddr_in sa = {0};
  sa.sin_len = sizeof(sa);
  sa.sin_family = AF_INET;
  sa.sin_port = htons((uint16_t)port);
  if (inet_pton(AF_INET, ip, &sa.sin_addr) != 1) return -1;
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  int fl = fcntl(fd, F_GETFL);
  fcntl(fd, F_SETFL, fl | O_NONBLOCK);
  int rc = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
  if (rc < 0 && errno == EINPROGRESS) {
    struct pollfd p = { fd, POLLOUT, 0 };
    int err = 0; socklen_t el = sizeof(err);
    rc = poll(&p, 1, timeout_ms) == 1 && !getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el) && !err ? 0 : -1;
    if (rc < 0) errno = err ? err : ETIMEDOUT;
  }
  if (rc < 0) { close(fd); return -1; }
  fcntl(fd, F_SETFL, fl);
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
  return fd;
}

/* Try each space/comma separated URI once. */
static int try_uris(const char *uris, char *addr, size_t addrlen) {
  char *list = strdup(uris), *save = NULL;
  int fd = -1;
  for (char *u = strtok_r(list, " ,", &save); u && fd < 0; u = strtok_r(NULL, " ,", &save)) {
    char host[256], ip[64];
    int port;
    if (uri_host(u, host, sizeof(host), &port, 0)) continue;
    if (resolve_ipv4(host, ip, sizeof(ip))) { fprintf(stderr, "INFO: Cannot resolve %s\n", host); continue; }
    if (use_nc()) {
      fd = nc_open(ip, port);
      if (fd < 0) fprintf(stderr, "INFO: %s:%d (%s) not reachable\n", host, port, ip);
    } else {
      errno = 0;
      fd = tcp_connect(ip, port, 8000);
      if (fd < 0) fprintf(stderr, "INFO: Connect to %s:%d failed: %s\n", ip, port, errno ? strerror(errno) : "timeout");
    }
    if (fd >= 0) snprintf(addr, addrlen, "%s", ip);
  }
  free(list);
  return fd;
}

int device_open(const char *uris, int retry_seconds, char *addr, size_t addrlen) {
  if (!parent_pid) parent_pid = getppid();
  time_t give_up = mono() + retry_seconds;
  int announced = 0;
  for (;;) {
    int fd = try_uris(uris, addr, addrlen);
    if (fd >= 0) {
      if (announced) fprintf(stderr, "STATE: -offline-report\n");
      fprintf(stderr, "INFO: Connected to printer at %s\n", addr);
      return fd;
    }
    if (mono() >= give_up || orphaned()) {
      fprintf(stderr, "ERROR: Printer not reachable (%s)\n", uris);
      return -1;
    }
    if (!announced) {
      fprintf(stderr, "STATE: +offline-report\nINFO: Printer not reachable, retrying...\n");
      announced = 1;
    }
    sleep(10);
  }
}

int device_close(int fd) {
  close(fd);
  if (nc_pid < 0) return 0;
  int rc = wait_child(nc_pid, 30 * 60);          /* long enough to clear a paper jam */
  nc_pid = -1;
  char buf[1024];
  ssize_t n = nc_err >= 0 ? read(nc_err, buf, sizeof(buf) - 1) : 0;
  buf[n > 0 ? n : 0] = '\0';
  if (nc_err >= 0) close(nc_err);
  nc_err = -1;
  if (rc) {
    nc_report(buf);
    fprintf(stderr, "ERROR: Sending to the printer failed (nc exit %d)\n", rc);
  }
  return rc ? -1 : 0;
}

/* ------------------------------------------------------------------------ */
/* SNMP status                                                               */
/* ------------------------------------------------------------------------ */

#define OID_DESCR   "1.3.6.1.2.1.1.1.0"             /* sysDescr */
#define OID_PAGES   "1.3.6.1.2.1.43.10.2.1.4.1.1"   /* prtMarkerLifeCount */
#define OID_STATUS  "1.3.6.1.2.1.25.3.5.1.1.1"      /* hrPrinterStatus: 3 idle, 4 printing, 5 warmup */
#define OID_ERRORS  "1.3.6.1.2.1.25.3.5.1.2.1"      /* hrPrinterDetectedErrorState bits */
#define OID_TONER_MAX "1.3.6.1.2.1.43.11.1.1.8.1.1" /* prtMarkerSuppliesMaxCapacity */
#define OID_TONER   "1.3.6.1.2.1.43.11.1.1.9.1.1"   /* prtMarkerSuppliesLevel (-3 = some left) */

typedef struct { long pages; int status; unsigned errors; int toner; } snmp_state_t;

/* snmpget's agent argument: the printer, or udp:IP:PORT when UFR2LT_SNMP_PORT is
 * set (soak tests talk to a fake agent on an unprivileged port). */
static const char *snmp_agent(const char *ip, char *buf, size_t len) {
  const char *port = getenv("UFR2LT_SNMP_PORT");
  if (!port || !*port) return ip;
  snprintf(buf, len, "udp:%s:%s", ip, port);
  return buf;
}

static int snmp_poll(const char *ip, snmp_state_t *st) {
  char out[256], agent[96];
  char *argv[] = { SNMPGET, "-v1", "-c", "public", "-t", "2", "-r", "1", "-Oqv", "-Ox", "-Oe",
                   (char *)snmp_agent(ip, agent, sizeof(agent)), OID_PAGES, OID_STATUS, OID_ERRORS,
                   OID_TONER_MAX, OID_TONER, NULL };
  if (run_capture(argv, out, sizeof(out), 10) != 0) return -1;
  char *save = NULL;                              /* strtok_r: the monitor thread polls too */
  char *l1 = strtok_r(out, "\n", &save), *l2 = strtok_r(NULL, "\n", &save), *l3 = strtok_r(NULL, "\n", &save);
  char *l4 = strtok_r(NULL, "\n", &save), *l5 = strtok_r(NULL, "\n", &save);
  if (!l1 || !l2 || !l3) return -1;
  st->pages = atol(l1);
  st->status = atoi(l2);
  long max = l4 ? atol(l4) : 0, level = l5 ? atol(l5) : -1;
  st->toner = max > 0 && level >= 0 ? (int)(level * 100 / max) : -1;
  unsigned b[2] = {0, 0};                         /* error bits come back as hex octets: "40 00" */
  int n = 0;
  for (char *s = l3; *s && n < 2; ) {
    while (*s && !strchr("0123456789abcdefABCDEF", *s)) s++;
    if (!*s) break;
    b[n++] = (unsigned)strtoul(s, &s, 16);
  }
  st->errors = (b[0] << 8) | b[1];
  return 0;
}

static int snmp_descr_has(const char *ip, const char *text) {
  char out[256], agent[96];
  char *argv[] = { SNMPGET, "-v1", "-c", "public", "-t", "2", "-r", "1", "-Oqv",
                   (char *)snmp_agent(ip, agent, sizeof(agent)), OID_DESCR, NULL };
  return run_capture(argv, out, sizeof(out), 10) == 0 && strstr(out, text) != NULL;
}

static int snmp_is_canon(const char *ip) { return snmp_descr_has(ip, "Canon"); }

int device_find(const char *uris, char *addr, size_t addrlen) {
  char *list = strdup(uris), *save = NULL;
  int found = 0;
  for (char *u = strtok_r(list, " ,", &save); u && !found; u = strtok_r(NULL, " ,", &save)) {
    char host[256], ip[64];
    int port;
    if (uri_host(u, host, sizeof(host), &port, 1) || resolve_ipv4(host, ip, sizeof(ip))) continue;
    if ((found = snmp_is_canon(ip))) snprintf(addr, addrlen, "%s", ip);
  }
  free(list);
  return found ? 0 : -1;
}

int device_status_line(const char *addr, char *buf, size_t buflen) {
  static const char *names[] = { "unknown", "other", "unknown", "idle", "printing", "warmup" };
  snmp_state_t st;
  if (snmp_poll(addr, &st)) return -1;
  snprintf(buf, buflen, "%s %ld %04x %d", st.status >= 1 && st.status <= 5 ? names[st.status] : "unknown",
           st.pages, st.errors, st.toner);
  return 0;
}

/* hrPrinterDetectedErrorState bit (MSB of first octet = bit 0) -> IPP reason */
static const struct { unsigned mask; const char *reason; } reasons[] = {
  { 0x8000, "media-low-report" },
  { 0x4000, "media-empty-error" },
  { 0x2000, "toner-low-report" },
  { 0x1000, "toner-empty-error" },
  { 0x0800, "door-open-error" },
  { 0x0400, "media-jam-error" },
  { 0x0200, "offline-report" },
  { 0x0100, "other-error" },
  { 0x0080, "input-tray-missing-error" },
  { 0x0004, "media-empty-warning" },              /* inputTrayEmpty: maybe just one tray */
};
#define BLOCKING_ERRORS 0x5d80                    /* no paper/toner, door, jam, service, tray missing */

struct device_monitor {
  pthread_t thread;
  pthread_mutex_t lock;
  char addr[64];
  int stop, have;
  unsigned shown;                                 /* reasons currently announced */
  snmp_state_t start, last;
};

static void announce(device_monitor_t *m, unsigned errors) {
  unsigned want = 0;
  for (size_t i = 0; i < sizeof(reasons) / sizeof(reasons[0]); i++)
    if (errors & reasons[i].mask) want |= 1u << i;
  for (size_t i = 0; i < sizeof(reasons) / sizeof(reasons[0]); i++) {
    unsigned bit = 1u << i;
    if ((want & bit) && !(m->shown & bit)) fprintf(stderr, "STATE: +%s\n", reasons[i].reason);
    if (!(want & bit) && (m->shown & bit)) fprintf(stderr, "STATE: -%s\n", reasons[i].reason);
  }
  m->shown = want;
}

static void *monitor_thread(void *arg) {
  device_monitor_t *m = arg;
  for (;;) {
    snmp_state_t st;
    if (!snmp_poll(m->addr, &st)) {
      pthread_mutex_lock(&m->lock);
      if (!m->have) { m->start = st; m->have = 1; }
      m->last = st;
      announce(m, st.errors);
      pthread_mutex_unlock(&m->lock);
    }
    for (int i = 0; i < 20; i++) {                /* 2 s, responsive to stop */
      usleep(100000);
      pthread_mutex_lock(&m->lock);
      int stop = m->stop;
      pthread_mutex_unlock(&m->lock);
      if (stop) return NULL;
    }
  }
}

device_monitor_t *device_monitor_start(const char *addr) {
  device_monitor_t *m = calloc(1, sizeof(*m));
  if (!m) return NULL;
  snprintf(m->addr, sizeof(m->addr), "%s", addr);
  pthread_mutex_init(&m->lock, NULL);
  snmp_state_t st;
  if (!snmp_poll(m->addr, &st)) { m->start = m->last = st; m->have = 1; announce(m, st.errors); }
  if (pthread_create(&m->thread, NULL, monitor_thread, m)) { pthread_mutex_destroy(&m->lock); free(m); return NULL; }
  return m;
}

void device_monitor_finish(device_monitor_t *m, int impressions, int timeout_s) {
  if (!m) return;
  time_t start = mono(), deadline = start + timeout_s;
  int idle_polls = 0;
  long reported = -1;
  while (mono() < deadline && !orphaned()) {
    sleep(2);
    pthread_mutex_lock(&m->lock);
    snmp_state_t st = m->last, s0 = m->start;
    int have = m->have;
    pthread_mutex_unlock(&m->lock);
    if (!have) continue;
    long done = st.pages - s0.pages;
    if (done != reported && done >= 0) {
      fprintf(stderr, "ATTR: job-impressions-completed=%ld\n", done);
      reported = done;
    }
    idle_polls = st.status == 3 ? idle_polls + 1 : 0;
    if (done >= impressions && idle_polls >= 1) break;   /* printed; lingering warnings don't matter */
    if (st.errors & BLOCKING_ERRORS) {             /* keep the job open until the user fixes it */
      deadline = mono() + 30 * 60;
      idle_polls = 0;
      continue;
    }
    if (idle_polls >= 5 && mono() - start > 20) break;  /* idle for 10 s: counter may lag */
  }
  pthread_mutex_lock(&m->lock);
  m->stop = 1;
  pthread_mutex_unlock(&m->lock);
  pthread_join(m->thread, NULL);
  announce(m, m->last.errors & 0xa000);            /* keep only low-paper/low-toner warnings */
  pthread_mutex_destroy(&m->lock);
  free(m);
}
