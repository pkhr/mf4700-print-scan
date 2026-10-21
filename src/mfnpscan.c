/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * mfnpscan - scan from Canon imageCLASS / i-SENSYS MF printers over the network
 * (Canon "MFNP" protocol, UDP+TCP port 8610), e.g. the MF4700 series.
 *
 * Protocol as documented by the SANE pixma backend (pixma_bjnp.c,
 * pixma_imageclass.c): UDP job details open a session, then TCP carries
 * imageCLASS scanner commands (status f320, start db20, source dd20,
 * parameters de20, read d460, abort ef20) framed in 16-byte MFNP headers.
 *
 *   mfnpscan [-r dpi] [-m color|gray] [-s auto|flatbed|adf] [-o dir] [-v] PRINTER-IP
 *   mfnpscan --status PRINTER-IP        report whether the scanner accepts a session
 *   mfnpscan --wait [options] PRINTER-IP  list this Mac under SCAN → Computer on the
 *                                       printer (as -n NAME), scan when Start is
 *                                       pressed for it
 *
 * Pages are written as dir/page-N.pnm (P6 colour / P5 gray) and listed on stdout
 * as they complete, also when a later page fails. Exit codes: 0 scanned, 2 scanner
 * offline (select Remote Scanner on the printer), 3 ADF empty, 4 printer unreachable
 * (--wait), 5 the printer stopped the scan (paper jam, Stop key), 6 cancelled
 * (SIGTERM/SIGINT), 1 other errors.
 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MFNP_PORT 8610
#define EXIT_OFFLINE 2
#define EXIT_NO_PAPER 3
#define EXIT_UNREACHABLE 4
#define EXIT_STOPPED 5
#define EXIT_CANCELLED 6

static int verbose;
static int reply_ms = 10000;                      /* per TCP reply (SANE waits 8 s) */
static volatile sig_atomic_t cancelled;

static void on_cancel(int sig) { (void)sig; cancelled = 1; }

typedef struct __attribute__((packed)) {
  char id[4];                 /* "MFNP" */
  uint8_t dev_type;           /* 2 = scanner command, 0x82 = scanner response */
  uint8_t cmd;
  uint16_t status;            /* 0 = ok; seen 0x8300/0x8500 when the device refuses */
  uint16_t seq;
  uint16_t session;
  uint32_t len;               /* payload length */
} mfnp_hdr_t;

enum { CMD_UDP_JOB_DETAILS = 0x10, CMD_UDP_CLOSE = 0x11, CMD_TCP_REQ = 0x20, CMD_TCP_SEND = 0x21 };
enum { ICLASS_STATUS = 0xf320, ICLASS_START = 0xdb20, ICLASS_SOURCE = 0xdd20, ICLASS_PARAM = 0xde20,
       ICLASS_ABORT = 0xef20, ICLASS_READ2 = 0xd460, ICLASS_ERROR_INFO = 0xff20 };
enum { ST_OK = 0x0606, ST_BUSY = 0x1414, ST_FAILED = 0x1515 };

typedef struct {
  struct sockaddr_in addr;
  int udp, tcp;
  uint16_t seq, session;
  uint8_t last_cmd;
  size_t data_left, blocksize;
  int last_block;
  int timed_out;              /* a TCP reply never came: the session is dead */
} mfnp_t;

static void hexdump(const char *what, const void *p, size_t n) {
  if (!verbose) return;
  const uint8_t *b = p;
  fprintf(stderr, "%s (%zu):", what, n);
  for (size_t i = 0; i < n && i < 64; i++) fprintf(stderr, " %02x", b[i]);
  fprintf(stderr, n > 64 ? " ...\n" : "\n");
}

static void put16(uint8_t *p, unsigned v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }
static void put32(uint8_t *p, uint32_t v) { put16(p, v >> 16); put16(p + 2, v & 0xffff); }
static unsigned get16(const uint8_t *p) { return (unsigned)p[0] << 8 | p[1]; }
static uint32_t get32(const uint8_t *p) { return (uint32_t)get16(p) << 16 | get16(p + 2); }

static void set_hdr(mfnp_t *m, mfnp_hdr_t *h, uint8_t cmd, uint32_t len) {
  memcpy(h->id, "MFNP", 4);
  h->dev_type = 2;
  h->cmd = cmd;
  h->status = 0;
  h->seq = htons(++m->seq);
  h->session = htons(m->session);
  h->len = htonl(len);
  m->last_cmd = cmd;
}

/* ------------------------------------------------------------------------ */
/* UDP                                                                       */
/* ------------------------------------------------------------------------ */

static int udp_cmd(mfnp_t *m, uint8_t cmd, const void *payload, size_t plen, uint8_t *resp, size_t rmax) {
  uint8_t buf[1024];
  mfnp_hdr_t *h = (mfnp_hdr_t *)buf;
  set_hdr(m, h, cmd, (uint32_t)plen);
  if (plen) memcpy(buf + sizeof(*h), payload, plen);
  hexdump("udp >", buf, sizeof(*h) + plen);
  for (int attempt = 0; attempt < 3; attempt++) {
    if (send(m->udp, buf, sizeof(*h) + plen, 0) < 0) {
      if (verbose) fprintf(stderr, "udp send: %s\n", strerror(errno));
      return -1;
    }
    struct pollfd p = { m->udp, POLLIN, 0 };
    while (poll(&p, 1, 1500) > 0) {
      ssize_t n = recv(m->udp, resp, rmax, 0);
      if (n < (ssize_t)sizeof(mfnp_hdr_t)) continue;
      mfnp_hdr_t *r = (mfnp_hdr_t *)resp;
      if (r->cmd == cmd && ntohs(r->seq) == m->seq) { hexdump("udp <", resp, (size_t)n); return (int)n; }
    }
  }
  return -1;
}

/* This computer as the printer shows it under SCAN → Computer (and in job
 * details): -n NAME, else the host name without ".local". ASCII only, since
 * the panel shows 8-bit text. */
static char computer[64];

static void set_computer_name(const char *name) {
  char host[256] = "";
  if (!name || !*name) {
    if (gethostname(host, sizeof(host) - 1)) strcpy(host, "Mac");
    char *dot = strstr(host, ".local");
    if (dot && !dot[6]) *dot = 0;
    name = host;
  }
  size_t n = 0;
  for (const unsigned char *p = (const unsigned char *)name; *p && n < sizeof(computer) - 1; p++)
    if (*p >= 0x20 && *p < 0x7f) computer[n++] = (char)*p;
  computer[n] = 0;
  if (!n) strcpy(computer, "Mac");
}

static const char *computer_name(void) {
  if (!computer[0]) set_computer_name(NULL);
  return computer;
}

static const char *user_name(void) {
  struct passwd *pw = getpwuid(getuid());
  return pw ? pw->pw_name : "user";
}

/* Announce the job (Canon's SessionStart: u32 retry count, u32 timestamp, 8-bit
 * computer[64], user[64], document[256]); the reply carries the session id.
 * Returns 0, or EXIT_OFFLINE if refused. */
static int job_details(mfnp_t *m) {
  uint8_t payload[8 + 64 + 64 + 256] = {0}, resp[256];
  strncpy((char *)payload + 8, computer_name(), 63);
  strncpy((char *)payload + 72, user_name(), 63);
  snprintf((char *)payload + 136, 256, "Scan %d", getpid());
  int n = udp_cmd(m, CMD_UDP_JOB_DETAILS, payload, sizeof(payload), resp, sizeof(resp));
  if (n < 0) { fprintf(stderr, "ERROR: scanner does not answer on UDP %d\n", MFNP_PORT); return 1; }
  mfnp_hdr_t *r = (mfnp_hdr_t *)resp;
  m->session = ntohs(r->session);
  if (r->status || !m->session) {
    if (verbose) fprintf(stderr, "job refused: status %04x session %u\n", ntohs(r->status), m->session);
    return EXIT_OFFLINE;
  }
  return 0;
}

static void job_close(mfnp_t *m) {
  uint8_t resp[64];
  udp_cmd(m, CMD_UDP_CLOSE, NULL, 0, resp, sizeof(resp));
}

/* ------------------------------------------------------------------------ */
/* TCP                                                                       */
/* ------------------------------------------------------------------------ */

static int recv_all(int fd, void *buf, size_t n, int timeout_ms) {
  uint8_t *p = buf;
  while (n) {
    if (cancelled) return -1;
    struct pollfd pf = { fd, POLLIN, 0 };
    int ready = poll(&pf, 1, timeout_ms);
    if (ready < 0 && errno == EINTR) continue;
    if (ready <= 0) return -1;
    ssize_t r = recv(fd, p, n, 0);
    if (r <= 0) return -1;
    p += r; n -= (size_t)r;
  }
  return 0;
}

static int recv_hdr(mfnp_t *m, uint32_t *len) {
  mfnp_hdr_t h;
  if (recv_all(m->tcp, &h, sizeof(h), reply_ms)) {
    if (!cancelled) fprintf(stderr, "ERROR: no reply from scanner\n");
    m->timed_out = 1;
    return -1;
  }
  hexdump("tcp < hdr", &h, sizeof(h));
  if (h.cmd != m->last_cmd || ntohs(h.seq) != m->seq) { fprintf(stderr, "ERROR: out-of-sequence reply\n"); return -1; }
  if (h.status) fprintf(stderr, "INFO: scanner reply status %04x\n", ntohs(h.status));
  *len = ntohl(h.len);
  return 0;
}

static int tcp_write(mfnp_t *m, const uint8_t *data, size_t n) {
  uint8_t buf[sizeof(mfnp_hdr_t) + 512];
  set_hdr(m, (mfnp_hdr_t *)buf, CMD_TCP_SEND, (uint32_t)n);
  memcpy(buf + sizeof(mfnp_hdr_t), data, n);
  hexdump("tcp >", buf, sizeof(mfnp_hdr_t) + n);
  if (send(m->tcp, buf, sizeof(mfnp_hdr_t) + n, 0) != (ssize_t)(sizeof(mfnp_hdr_t) + n)) return -1;
  uint32_t len;
  uint8_t ack[4];
  if (recv_hdr(m, &len)) return -1;
  if (len != 4) {                                 /* device refused the command */
    fprintf(stderr, "ERROR: scanner refused command %02x%02x (%u-byte ack)\n", data[0], data[1], len);
    return -1;
  }
  if (recv_all(m->tcp, ack, 4, reply_ms) || get32(ack) != n) {
    fprintf(stderr, "ERROR: scanner accepted %u of %zu bytes\n", get32(ack), n);
    return -1;
  }
  m->last_block = 0;
  return 0;
}

/* Read up to max bytes of scanner output (one or more TCP read requests). */
static ssize_t tcp_read(mfnp_t *m, uint8_t *buf, size_t max) {
  size_t got = 0;
  while (got < max && !(m->last_block && !m->data_left)) {
    if (!m->data_left) {
      mfnp_hdr_t h;
      set_hdr(m, &h, CMD_TCP_REQ, 0);
      if (send(m->tcp, &h, sizeof(h), 0) != sizeof(h)) return -1;
      uint32_t len;
      if (recv_hdr(m, &len)) return -1;
      m->data_left = len;
      if (len > m->blocksize) m->blocksize = len;
      if (len < m->blocksize) m->last_block = 1;  /* a short block ends the data */
      if (!len) break;
    }
    size_t n = m->data_left < max - got ? m->data_left : max - got;
    if (recv_all(m->tcp, buf + got, n, reply_ms)) return -1;
    got += n;
    m->data_left -= n;
  }
  return (ssize_t)got;
}

/* ------------------------------------------------------------------------ */
/* imageCLASS commands                                                       */
/* ------------------------------------------------------------------------ */

/* Send a command (10-byte header + data with trailing checksum) and read the reply. */
static int iclass_cmd(mfnp_t *m, unsigned cmd, const uint8_t *data, size_t dataout, uint8_t *reply, size_t datain) {
  uint8_t buf[128];
  memset(buf, 0, sizeof(buf));
  put16(buf, cmd);
  put16(buf + 7, (unsigned)(dataout + datain));
  if (dataout) {
    memcpy(buf + 10, data, dataout);
    uint8_t sum = 0;
    for (size_t i = 0; i + 1 < dataout; i++) sum += buf[10 + i];
    buf[10 + dataout - 1] = (uint8_t)-sum;
  }
  if (tcp_write(m, buf, 10 + dataout)) return -1;
  uint8_t res[64];
  ssize_t n = tcp_read(m, res, 2 + datain);
  if (n < 2) return -1;
  hexdump("reply", res, (size_t)n);
  unsigned status = get16(res);
  if (reply && datain && n == (ssize_t)(2 + datain)) memcpy(reply, res + 2, datain);
  return (int)status;
}

static int query_status(mfnp_t *m, uint8_t st[12]) { return iclass_cmd(m, ICLASS_STATUS, NULL, 0, st, 12); }
static int has_adf_paper(const uint8_t st[12]) { return (st[1] & 0x0f) == 0 || st[1] == 0x51; }

typedef struct { int dpi, channels, x, y, w, h, raw_w; } scanparam_t;

static int send_params(mfnp_t *m, const scanparam_t *p) {
  uint8_t d[0x2e] = {0};
  put16(d + 0x04, (unsigned)p->dpi | 0x1000);
  put16(d + 0x06, (unsigned)p->dpi | 0x1000);
  put32(d + 0x08, (uint32_t)p->x);
  put32(d + 0x0c, (uint32_t)p->y);
  put32(d + 0x10, (uint32_t)p->raw_w);
  put32(d + 0x14, (uint32_t)p->h);
  d[0x18] = p->channels == 1 ? 0x04 : 0x08;
  d[0x19] = (uint8_t)(p->channels * 8);
  d[0x1f] = 0x7f;
  d[0x20] = 0xff;
  d[0x23] = 0x81;
  return iclass_cmd(m, ICLASS_PARAM, d, sizeof(d), NULL, 0);
}

/* Ask for the next image block. Returns bytes of block data still to read (after
 * the first chunk copied to *first), sets *info (0x28 = page end, 0x38 = end + ADF
 * empty). -2: the scanner says the scan failed (paper jam, Stop key), -1: other errors. */
static ssize_t request_block(mfnp_t *m, int flag, uint8_t *first, size_t *first_len, uint8_t *info) {
  uint8_t cmd[11] = {0};
  put16(cmd, ICLASS_READ2);
  cmd[8] = (uint8_t)flag;
  cmd[10] = 0x06;
  if (tcp_write(m, cmd, sizeof(cmd))) return -1;
  uint8_t res[512];
  ssize_t n = tcp_read(m, res, sizeof(res));
  if (n >= 2 && get16(res) == ST_FAILED) {
    fprintf(stderr, "INFO: image block refused:");
    for (ssize_t i = 0; i < n && i < 16; i++) fprintf(stderr, " %02x", res[i]);
    fprintf(stderr, "\n");
    return -2;
  }
  if (n < 8) {
    if (!cancelled && !m->timed_out) fprintf(stderr, "ERROR: short image block header (%zd bytes)\n", n);
    return -1;
  }
  hexdump("block hdr", res, 8);
  if (get16(res) != ST_OK || (res[2] & ~0x38))
    fprintf(stderr, "INFO: unexpected image block header %02x %02x %02x\n", res[0], res[1], res[2]);
  *info = res[2];
  size_t datalen = (size_t)n - 8;
  size_t size = n == 512 ? get32(res + 4) - datalen : get16(res + 6);
  if (first) { memcpy(first, res + 8, datalen); *first_len = datalen; }
  return (ssize_t)size;
}

static int write_pnm(const char *dir, int page, const scanparam_t *p, const uint8_t *img, int lines) {
  char path[1024];
  snprintf(path, sizeof(path), "%s/page-%d.pnm", dir, page);
  FILE *f = fopen(path, "wb");
  if (!f) { perror(path); return -1; }
  fprintf(f, "P%d\n%d %d\n255\n", p->channels == 3 ? 6 : 5, p->w, lines);
  size_t stride = (size_t)p->raw_w * p->channels;
  for (int y = 0; y < lines; y++) fwrite(img + (size_t)y * stride, 1, (size_t)p->w * p->channels, f);
  fclose(f);
  printf("PAGE %d %s %d %d %d\n", page, path, p->w, lines, p->dpi);
  fflush(stdout);
  return 0;
}

/* Scan one page into a newly allocated buffer of raw_w*channels-byte lines.
 * Returns NULL with *rc set (EXIT_STOPPED, EXIT_CANCELLED or 1) on failure. */
static uint8_t *scan_page(mfnp_t *m, const scanparam_t *p, int *lines, uint8_t *last_info, int *rc) {
  size_t stride = (size_t)p->raw_w * p->channels, cap = stride * p->h, have = 0;
  uint8_t *img = malloc(cap + 0x10000);
  uint8_t info = 0, *chunk = malloc(0x10000);
  time_t progress = time(NULL);                    /* last time the scanner sent data */
  int failure = 1;
  for (;;) {
    if (cancelled) { failure = EXIT_CANCELLED; goto fail; }
    size_t first = 0;
    ssize_t left = request_block(m, 4, chunk, &first, &info);
    if (left == -2) {
      fprintf(stderr, "ERROR: the printer stopped the scan (paper jam or Stop key?)\n");
      failure = EXIT_STOPPED;
      goto fail;
    }
    if (left < 0) {
      if (cancelled) { failure = EXIT_CANCELLED; goto fail; }
      if (m->timed_out) {
        fprintf(stderr, "ERROR: the scanner stopped responding after %zu bytes (paper jam?)\n", have);
        goto fail;
      }
      /* Like SANE: a block request can fail transiently (e.g. while the feeder
       * pulls a sheet in); read the error info and try again for a while. */
      uint8_t ei[16];
      if (iclass_cmd(m, ICLASS_ERROR_INFO, NULL, 0, ei, sizeof(ei)) == ST_FAILED) {
        fprintf(stderr, "ERROR: the printer stopped the scan (paper jam or Stop key?)\n");
        failure = EXIT_STOPPED;
        goto fail;
      }
      if (m->timed_out || time(NULL) - progress > 20) {
        fprintf(stderr, "ERROR: the scanner stopped responding after %zu bytes (paper jam?)\n", have);
        goto fail;
      }
      usleep(200000);
      continue;
    }
    if (have + first <= cap) { memcpy(img + have, chunk, first); have += first; }
    while (left > 0) {
      size_t want = left > 0x4000 ? 0x4000 : (size_t)left;
      ssize_t n = tcp_read(m, chunk, want);
      if (n <= 0) {
        if (cancelled) { failure = EXIT_CANCELLED; goto fail; }
        fprintf(stderr, "ERROR: image data stopped after %zu bytes\n", have);
        goto fail;
      }
      size_t take = have + (size_t)n <= cap ? (size_t)n : cap - have;
      memcpy(img + have, chunk, take);
      have += take;
      left -= n;
    }
    if (info & 0x38) break;                       /* end of page */
    if (!first && left == 0) {                    /* nothing yet: scanner still moving */
      if (time(NULL) - progress > 30) {
        fprintf(stderr, "ERROR: the scanner stopped sending data after %zu bytes (paper jam?)\n", have);
        goto fail;
      }
      usleep(100000);
    } else progress = time(NULL);
  }
  free(chunk);
  *lines = (int)(have / stride);
  *last_info = info;
  return img;
fail:
  free(img);
  free(chunk);
  *rc = failure;
  return NULL;
}

/* ------------------------------------------------------------------------ */
/* SCAN → Computer: Start on the printer's panel triggers the scan           */
/* ------------------------------------------------------------------------ */

/* The MF lists a computer under SCAN → Computer while it polls the printer with
 * MFNP Notify packets (UDP 0x32), laid out as Canon's MF Scan Agent (MF Toolbox
 * for Mac, ProtocolMFNP) sends them:
 *   u16 type, u16 0, u32 timestamp (from the register reply), char computer[64]
 *   (8-bit), u32 interrupt-data length, u32 app-info length, app info.
 * Types: 0 inquire, 1 register, 2 polling, 4 cancel, 5 polling ack. Reply: u16 0,
 * u16 status (0 ok, 1 rejected, 2 info, 3 throttling, 0x8000 event), u32 timestamp,
 * u32 interrupt-data length, u32 event id, u8 key id, u32 app-info length.
 * Register's app info is the name shown on the panel (UTF-8, 193 bytes), a u16
 * button count and per button: u8 key id, u8 colour mode, 121 bytes name. The
 * MF4700 series reports key 1 Color, 2 B&W, 3 Custom 1, 4 Custom 2. Canon polls
 * every 4 s, and every 6 s after throttling or an event. */
enum { CMD_UDP_NOTIFY = 0x32 };
enum { NOTIFY_INQUIRE = 0, NOTIFY_REGISTER = 1, NOTIFY_POLLING = 2, NOTIFY_CANCEL = 4, NOTIFY_ACK = 5 };
enum { NOTIFY_OK = 0, NOTIFY_REJECTED = 1, NOTIFY_THROTTLING = 3, NOTIFY_EVENT = 0x8000 };

typedef struct { uint32_t timestamp; uint8_t reply[64]; size_t reply_len; } notify_t;

/* Returns the reply status, or -1 when the printer does not answer. */
static int notify(mfnp_t *m, notify_t *d, int type) {
  uint8_t pl[0x50 + 0xc3 + 4 * 0x7b] = {0}, resp[256];
  size_t info = 0;
  put16(pl, (unsigned)type);
  if (type != NOTIFY_INQUIRE && type != NOTIFY_REGISTER) put32(pl + 4, d->timestamp);
  strncpy((char *)pl + 8, computer_name(), 63);
  if (type == NOTIFY_POLLING) {                     /* app info: the local time */
    time_t t = time(NULL);
    strftime((char *)pl + 0x50, 16, "%Y%m%d%H%M%S", localtime(&t));
    info = 16;
  } else if (type == NOTIFY_REGISTER) {
    static const struct { uint8_t key, mode; const char *name; } buttons[] = {
      { 1, 4, "Color" }, { 2, 1, "B&W" }, { 3, 4, "Custom 1" }, { 4, 4, "Custom 2" },
    };
    uint8_t *a = pl + 0x50;
    strncpy((char *)a, computer_name(), 192);
    put16(a + 0xc1, 4);
    for (int i = 0; i < 4; i++) {
      uint8_t *e = a + 0xc3 + i * 0x7b;
      e[0] = buttons[i].key;
      e[1] = buttons[i].mode;                       /* 1 black & white, 4 colour */
      snprintf((char *)e + 2, 121, "%-8s", buttons[i].name);
    }
    info = 0xc3 + 4 * 0x7b;
  }
  put32(pl + 0x4c, (uint32_t)info);
  int saved = verbose;
  verbose = 0;                                     /* a poll every 4 s: keep -v readable */
  int n = udp_cmd(m, CMD_UDP_NOTIFY, pl, 0x50 + info, resp, sizeof(resp));
  verbose = saved;
  if (n < (int)sizeof(mfnp_hdr_t) + 8) return -1;
  const uint8_t *r = resp + sizeof(mfnp_hdr_t);
  size_t rlen = (size_t)n - sizeof(mfnp_hdr_t);
  if (rlen > sizeof(d->reply)) rlen = sizeof(d->reply);
  if (verbose && (rlen != d->reply_len || memcmp(r, d->reply, rlen))) {
    fprintf(stderr, "notify %d <", type);
    for (size_t i = 0; i < rlen; i++) fprintf(stderr, " %02x", r[i]);
    fprintf(stderr, "\n");
  }
  memcpy(d->reply, r, rlen);
  d->reply_len = rlen;
  if (type == NOTIFY_REGISTER) d->timestamp = get32(r + 4);
  return (int)get16(r + 2);
}

/* Keep this computer listed until Start is pressed for it. Returns 0 on the event
 * (printed as "EVENT <reply>", *key = the panel's scan type), EXIT_UNREACHABLE when
 * the printer stops answering. Unregisters when cancelled. */
static int wait_for_start(mfnp_t *m, uint8_t *key) {
  notify_t d = {0};
  int listed = 0, failures = 0, wait = 0;
  pid_t parent = getppid();
  for (;;) {
    for (int i = 0; i < wait * 10 && !cancelled; i++) usleep(100000);
    if (cancelled || getppid() != parent) {        /* app quit or scanning switched off */
      if (listed) notify(m, &d, NOTIFY_CANCEL);
      return cancelled ? EXIT_CANCELLED : 1;
    }
    if (!listed) {
      int st = notify(m, &d, NOTIFY_INQUIRE);
      if (st == NOTIFY_OK) st = notify(m, &d, NOTIFY_REGISTER);
      if (st < 0) {
        if (++failures >= 10) { fprintf(stderr, "ERROR: the printer does not answer\n"); return EXIT_UNREACHABLE; }
        wait = 4;
        continue;
      }
      failures = 0;
      listed = st == NOTIFY_OK;
      if (listed) fprintf(stderr, "INFO: listed on the printer as \"%s\"\n", computer_name());
      else fprintf(stderr, "INFO: the printer refused the registration (%04x)\n", st);
      wait = listed ? 4 : 30;
      continue;
    }
    int st = notify(m, &d, NOTIFY_POLLING);
    if (st < 0) {
      if (++failures >= 10) { fprintf(stderr, "ERROR: the printer does not answer\n"); return EXIT_UNREACHABLE; }
      wait = 4;
      continue;
    }
    failures = 0;
    wait = st == NOTIFY_THROTTLING ? 6 : 4;
    if (st == NOTIFY_REJECTED) { listed = 0; wait = 0; continue; }   /* e.g. the printer restarted */
    if (st == NOTIFY_EVENT) {
      printf("EVENT");
      for (size_t i = 0; i < d.reply_len; i++) printf(" %02x", d.reply[i]);
      printf("\n");
      fflush(stdout);
      *key = d.reply_len > 16 ? d.reply[16] : 1;
      notify(m, &d, NOTIFY_ACK);
      return 0;
    }
  }
}

static int connect_tcp(mfnp_t *m) {
  m->tcp = socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  setsockopt(m->tcp, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  setsockopt(m->tcp, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
  if (connect(m->tcp, (struct sockaddr *)&m->addr, sizeof(m->addr))) { perror("connect"); return -1; }
  m->blocksize = 512;
  m->data_left = 0;
  m->last_block = 0;
  return 0;
}

static void close_session(mfnp_t *m) {
  if (m->tcp >= 0) close(m->tcp);
  m->tcp = -1;
  job_close(m);
  m->session = 0;
}

/* Job details (UDP), TCP, status, start. Returns 0 with the scanner started,
 * EXIT_OFFLINE when it refuses (no Remote Scanner / Start on the panel), 1 on errors. */
static int open_session(mfnp_t *m, uint8_t st[12]) {
  int rc = job_details(m);
  if (rc) { if (m->session) job_close(m); m->session = 0; return rc; }
  if (connect_tcp(m)) { close_session(m); return 1; }
  int s = query_status(m, st);
  if (s != ST_OK) { fprintf(stderr, "ERROR: status query failed (%04x)\n", s); rc = 1; }
  else if ((s = iclass_cmd(m, ICLASS_START, NULL, 0, NULL, 0)) == ST_BUSY) rc = EXIT_OFFLINE;
  else if (s != ST_OK) { fprintf(stderr, "ERROR: start session failed (%04x)\n", s); rc = 1; }
  if (rc) close_session(m);
  return rc;
}

int main(int argc, char **argv) {
  int dpi = 300, channels = 3, status_only = 0, wait_start = 0;
  const char *source = "auto", *dir = ".", *ip = NULL;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "-r") && i + 1 < argc) dpi = atoi(argv[++i]);
    else if (!strcmp(argv[i], "-m") && i + 1 < argc) channels = !strcmp(argv[++i], "gray") ? 1 : 3;
    else if (!strcmp(argv[i], "-s") && i + 1 < argc) source = argv[++i];
    else if (!strcmp(argv[i], "-o") && i + 1 < argc) dir = argv[++i];
    else if (!strcmp(argv[i], "-v")) verbose = 1;
    else if (!strcmp(argv[i], "--status")) status_only = 1;
    else if (!strcmp(argv[i], "--wait")) wait_start = 1;
    else if (!strcmp(argv[i], "-n") && i + 1 < argc) set_computer_name(argv[++i]);
    else ip = argv[i];
  }
  if (!ip) { fprintf(stderr, "usage: mfnpscan [-r dpi] [-m color|gray] [-s auto|flatbed|adf] [-o dir] [-n name] [-v] [--status|--wait] IP\n"); return 1; }
  if (dpi != 75 && dpi != 150 && dpi != 300 && dpi != 600) dpi = 300;

  mfnp_t m = {0};
  m.addr.sin_family = AF_INET;
  m.addr.sin_port = htons(MFNP_PORT);
  if (inet_pton(AF_INET, ip, &m.addr.sin_addr) != 1) { fprintf(stderr, "bad address %s\n", ip); return 1; }
  signal(SIGPIPE, SIG_IGN);                        /* report a dropped socket instead of dying */
  struct sigaction sa;                             /* cancel: end the session, keep finished pages */
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = on_cancel;                       /* no SA_RESTART, so waits return early */
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);
  m.udp = socket(AF_INET, SOCK_DGRAM, 0);
  int one = 1;
  setsockopt(m.udp, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
  if (connect(m.udp, (struct sockaddr *)&m.addr, sizeof(m.addr))) { perror("udp"); return 1; }
  m.tcp = -1;

  int rc, s;
  if (wait_start) {
    uint8_t key = 0;
    if ((rc = wait_for_start(&m, &key))) return rc;
    if (key == 2) channels = 1;                    /* the panel's B&W Scan */
  }
  uint8_t st[12];
  /* after Start on the panel the printer may need a moment before it grants the session */
  for (int tries = 0; (rc = open_session(&m, st)) == EXIT_OFFLINE && wait_start && tries < 20 && !cancelled; tries++) sleep(1);
  if (cancelled && rc) return EXIT_CANCELLED;
  if (status_only) {
    printf("%s\n", rc ? "offline" : "online");
    if (!rc) { iclass_cmd(&m, ICLASS_ABORT, NULL, 0, NULL, 0); close_session(&m); }
    return rc;
  }
  if (rc) return rc;
  int adf = !strcmp(source, "adf") || (!strcmp(source, "auto") && has_adf_paper(st));
  if (!strcmp(source, "adf") && !has_adf_paper(st)) { rc = EXIT_NO_PAPER; goto abort; }

  uint8_t src[10] = {0};
  src[0] = adf ? 2 : 1;
  if ((s = iclass_cmd(&m, ICLASS_SOURCE, src, sizeof(src), NULL, 0)) != ST_OK) {
    fprintf(stderr, "ERROR: select source failed (%04x)\n", s);
    rc = 1;
    goto abort;
  }

  /* full area: 640 x 877 (flatbed) or 1050 (ADF, legal) lines at 75 dpi */
  scanparam_t p = { dpi, channels, 0, 0, 640 * dpi / 75, (adf ? 1050 : 877) * dpi / 75, 0 };
  p.raw_w = (p.w + 31) & ~31;
  mkdir(dir, 0755);
  fprintf(stderr, "INFO: scanning from %s, %d dpi %s\n", adf ? "feeder" : "glass", dpi, channels == 3 ? "colour" : "gray");
  for (int page = 1; ; page++) {
    if ((s = send_params(&m, &p)) != ST_OK) {
      rc = cancelled ? EXIT_CANCELLED : 1;
      if (m.timed_out) fprintf(stderr, "ERROR: the scanner stopped responding before page %d (paper jam?)\n", page);
      else if (!cancelled) fprintf(stderr, "ERROR: scan parameters rejected (%04x)\n", s);
      break;
    }
    uint8_t info, dummy[512];
    size_t dl;
    ssize_t started = request_block(&m, 0, dummy, &dl, &info);
    if (started < 0) {
      rc = cancelled ? EXIT_CANCELLED : started == -2 ? EXIT_STOPPED : 1;
      if (rc != EXIT_CANCELLED) fprintf(stderr, "ERROR: the scanner did not start page %d%s\n", page,
                                        rc == EXIT_STOPPED ? " (paper jam or Stop key?)" : "");
      break;
    }
    int lines;
    uint8_t *img = scan_page(&m, &p, &lines, &info, &rc);
    if (!img) break;
    write_pnm(dir, page, &p, img, lines);
    free(img);
    query_status(&m, st);
    query_status(&m, st);
    if (!adf || info == 0x38 || !has_adf_paper(st)) break;  /* done, or feeder empty */
  }
abort:
  reply_ms = 2000;                                 /* don't hang on a scanner that gave up */
  iclass_cmd(&m, ICLASS_ABORT, NULL, 0, NULL, 0);
  close_session(&m);
  return cancelled ? EXIT_CANCELLED : rc;
}
