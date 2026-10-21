/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * rastertoufr2lt - Canon UFR II LT encoder for MF4700-series printers.
 * Reads PWG raster / Apple raster (URF) / CUPS raster and produces the printer job.
 *
 * As the ippeveprinter(1) print command of the AirPrint app: job metadata comes
 * from IPP_* variables and UFR2LT_DEVICE names the printer, e.g.
 *   UFR2LT_DEVICE="dnssd://CanonMF4700 socket://192.168.1.20:9100" rastertoufr2lt job.urf
 * Standalone:
 *   rastertoufr2lt [options] file.ras > job.ufr
 *   rastertoufr2lt --pbm --paper A4 page1.pbm page2.pbm > job.ufr   (1-bit 600 dpi pages)
 *   rastertoufr2lt --find URIS    "IP state pages error-bits toner%" (Bonjour + SNMP only)
 *   rastertoufr2lt --probe URIS   open and close the printer's data port
 * Options: -o out  --device URIS  --title T  --user U  --host H  --copies N
 *          --collate|--no-collate  --paper NAME  --hres 1|2  --special-mode 0-4
 *          --time EPOCH[.ms]  --pbm  -v
 */
#include "ufr2lt.h"
#include "device.h"

#include <cups/raster.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

static int verbose;

/* ------------------------------------------------------------------------ */
/* Halftoning: 45-degree clustered-dot screen (8 px period, ~106 lpi at      */
/* 600 dpi, two dots per 8x8 tile) with Canon's dot-gain compensation curve  */
/* measured from its driver's output for this engine.                        */
/* ------------------------------------------------------------------------ */

static uint8_t screen[8][8];
static uint8_t tone[256];

static int cmp_spot(const void *a, const void *b) {
  const double *x = a, *y = b;
  if (x[0] != y[0]) return x[0] < y[0] ? 1 : -1;     /* darker-first */
  return x[1] < y[1] ? -1 : x[1] > y[1];             /* stable tie-break */
}

static void halftone_init(void) {
  double cell[64][4];
  for (int y = 0; y < 8; y++)
    for (int x = 0; x < 8; x++) {
      double u = (x + 0.5 + y + 0.5) / 8.0, v = (x + 0.5 - y - 0.5) / 8.0;
      u -= floor(u); v -= floor(v);
      double spot = cos(2 * M_PI * (u - 0.5)) + cos(2 * M_PI * (v - 0.5));
      double *c = cell[y * 8 + x];
      c[0] = round(spot * 1e6) / 1e6; c[1] = y * 8 + x; c[2] = x; c[3] = y;
    }
  qsort(cell, 64, sizeof(cell[0]), cmp_spot);
  for (int r = 0; r < 64; r++) screen[(int)cell[r][3]][(int)cell[r][2]] = (uint8_t)((r * 255 + 127) / 64);

  /* ink (0..1) -> dot coverage, piecewise linear through Canon's measurements */
  static const double kx[] = { 0.0, 0.10, 0.25, 0.50, 0.75, 0.90, 1.0 };
  static const double ky[] = { 0.0, 0.039, 0.070, 0.195, 0.469, 0.750, 1.0 };
  for (int i = 0; i < 256; i++) {
    double x = i / 255.0, y = 1.0;
    for (int k = 1; k < 7; k++)
      if (x <= kx[k]) { y = ky[k - 1] + (ky[k] - ky[k - 1]) * (x - kx[k - 1]) / (kx[k] - kx[k - 1]); break; }
    tone[i] = (uint8_t)lround(y * 255);
  }
}

/* ------------------------------------------------------------------------ */
/* Output                                                                    */
/* ------------------------------------------------------------------------ */

static ssize_t fd_write(void *ctx, const void *buf, size_t len) {
  int fd = *(int *)ctx;
  for (;;) {
    ssize_t r = write(fd, buf, len);
    if (r < 0 && errno == EINTR) continue;
    if (r < 0) fprintf(stderr, "ERROR: Unable to write print data: %s\n", strerror(errno));
    return r;
  }
}

/* ------------------------------------------------------------------------ */
/* Page assembly                                                             */
/* ------------------------------------------------------------------------ */

typedef struct {
  const ufr2lt_paper_t *paper;
  int mult;                     /* 1 = 600x600, 2 = 1200x600 */
  size_t stride;
  uint8_t *bits;                /* paper->h_px * stride, 1 = black */
} page_t;

static void page_alloc(page_t *pg, const ufr2lt_paper_t *paper, int mult) {
  pg->paper = paper;
  pg->mult = mult;
  pg->stride = ((size_t)paper->w_px * mult + 7) / 8;
  pg->bits = calloc(paper->h_px, pg->stride);
  if (!pg->bits) { fprintf(stderr, "ERROR: Out of memory\n"); exit(2); }
}

/* Render one input row of ink values (0 = white .. 255 = black) into output row oy. */
static void put_row(page_t *pg, int oy, const uint8_t *ink, int iw, int xres, int ox) {
  if (oy < 0 || oy >= pg->paper->h_px) return;
  uint8_t *row = pg->bits + (size_t)oy * pg->stride;
  const uint8_t *scr = screen[oy & 7];
  int W = pg->paper->w_px * pg->mult, outres = 600 * pg->mult, sh = pg->mult - 1;
  for (int X = 0; X < W; X++) {
    long sx = xres == outres ? (long)X - ox : ((long)X - ox) * xres / outres;
    if (X < ox || sx < 0 || sx >= iw) continue;
    /* at 1200x600 each screen cell spans two device pixels: same physical screen */
    if (tone[ink[sx]] > scr[(X >> sh) & 7]) row[X >> 3] |= (uint8_t)(0x80 >> (X & 7));
  }
}

/* Paper for a raster page: exact size match, else the job's media, else the smallest that fits. */
static const ufr2lt_paper_t *pick_paper(double pw, double ph, const ufr2lt_paper_t *fallback) {
  const ufr2lt_paper_t *p = ufr2lt_paper_by_size(pw, ph, 3.0);
  if (!p && pw > ph) {
    p = ufr2lt_paper_by_size(ph, pw, 3.0);
    if (p) fprintf(stderr, "INFO: Landscape page on %s will be clipped\n", p->name);
  }
  if (!p) p = fallback;
  if (!p) {
    p = ufr2lt_paper_fitting(pw, ph);
    fprintf(stderr, "INFO: Page size %.1fx%.1fpt not supported natively; using %s\n", pw, ph, p->name);
  }
  return p;
}

/* Read one raster page (header already read) into a page bitmap. mult 0 = from the raster. */
static int raster_page(cups_raster_t *ras, cups_page_header2_t *h, page_t *pg,
                       const ufr2lt_paper_t *forced, const ufr2lt_paper_t *fallback, int mult) {
  unsigned w = h->cupsWidth, ht = h->cupsHeight, bpp = h->cupsBitsPerPixel, bpl = h->cupsBytesPerLine;
  int xres = (int)h->HWResolution[0], yres = (int)h->HWResolution[1];
  if (!w || !ht || !bpl || xres <= 0 || yres <= 0) { fprintf(stderr, "ERROR: Bad raster header\n"); return -1; }
  /* A line must hold w pixels; sizes are capped (66 x 133 in at 600 dpi) so nothing overflows. */
  if (w > 40000 || ht > 80000 || (bpp != 1 && bpp != 8 && bpp != 16 && bpp != 24 && bpp != 32 && bpp != 48) ||
      (uint64_t)bpl < ((uint64_t)w * bpp + 7) / 8) {
    fprintf(stderr, "ERROR: Unsupported raster (%ux%u, %u bits per pixel, %u bytes per line)\n", w, ht, bpp, bpl);
    return -1;
  }
  if (!mult) mult = xres == 2 * yres && xres >= 1200 ? 2 : 1;
  double pw = h->cupsPageSize[0] > 0 ? h->cupsPageSize[0] : h->PageSize[0];
  double ph = h->cupsPageSize[1] > 0 ? h->cupsPageSize[1] : h->PageSize[1];
  if (pw <= 0 || ph <= 0) { pw = w * 72.0 / xres; ph = ht * 72.0 / yres; }
  page_alloc(pg, forced ? forced : pick_paper(pw, ph, fallback), mult);

  int outres = 600 * mult;
  long iw_out = (long)w * outres / xres, ih_out = (long)ht * 600 / yres;
  int ox = (int)(((long)pg->paper->w_px * mult - iw_out) / 2);
  int oy = (int)(((long)pg->paper->h_px - ih_out) / 2);
  if (verbose)
    fprintf(stderr, "DEBUG: raster %ux%u %ubpp cs=%d %dx%ddpi page=%.1fx%.1fpt -> %s (%ux%u x%d) offset %d,%d\n",
            w, ht, bpp, h->cupsColorSpace, xres, yres, pw, ph, pg->paper->name,
            pg->paper->w_px, pg->paper->h_px, mult, ox, oy);

  uint8_t *line = malloc(bpl), *ink = malloc(w);
  if (!line || !ink) { fprintf(stderr, "ERROR: Out of memory\n"); free(line); free(ink); return -1; }
  int cs = h->cupsColorSpace;
  int additive = !(cs == CUPS_CSPACE_K || cs == CUPS_CSPACE_CMYK || cs == CUPS_CSPACE_KCMY ||
                   cs == CUPS_CSPACE_CMY || cs == CUPS_CSPACE_YMC);
  unsigned ncomp = h->cupsNumColors ? h->cupsNumColors : 1;
  for (unsigned y = 0; y < ht; y++) {
    if (cupsRasterReadPixels(ras, line, bpl) != bpl) {
      fprintf(stderr, "ERROR: Truncated raster at line %u\n", y);
      free(line); free(ink);
      return -1;
    }
    for (unsigned x = 0; x < w; x++) {
      unsigned v;
      if (bpp == 1) v = (line[x >> 3] >> (7 - (x & 7))) & 1 ? 255 : 0;
      else if (bpp == 8) v = line[x];
      else if (bpp == 16 && ncomp == 1) v = line[2 * x];
      else if (bpp == 24 || bpp == 48) {
        int s = bpp / 24;
        const uint8_t *p = line + (size_t)x * 3 * s;
        v = (p[0] * 299u + p[s] * 587u + p[2 * s] * 114u) / 1000;
      } else if (bpp == 32) {                   /* CMYK-ish: use K plus CMY average */
        const uint8_t *p = line + (size_t)x * 4;
        unsigned k = p[3], c = (p[0] + p[1] + p[2]) / 3;
        v = k + c > 255 ? 255 : k + c;
      } else v = line[(size_t)x * bpp / 8];
      ink[x] = (uint8_t)(additive ? 255 - v : v);
    }
    long y0 = (long)y * 600 / yres, y1 = (long)(y + 1) * 600 / yres;   /* output rows for this input row */
    for (long Y = y0; Y < y1; Y++) put_row(pg, (int)(Y + oy), ink, (int)w, xres, ox);
  }
  free(line);
  free(ink);
  return 0;
}

/* Read a P4 PBM (test mode). */
static int pbm_page(const char *path, page_t *pg, const ufr2lt_paper_t *paper, int mult) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); return -1; }
  int c1 = getc(f), c2 = getc(f), vals[2] = {0, 0}, n = 0;
  if (c1 != 'P' || c2 != '4') { fprintf(stderr, "%s: not a P4 PBM\n", path); fclose(f); return -1; }
  while (n < 2) {
    int c = getc(f);
    if (c == '#') {
      while ((c = getc(f)) != '\n' && c != EOF)
        ;
      continue;
    }
    if (c >= '0' && c <= '9') { int v = c - '0'; while ((c = getc(f)) >= '0' && c <= '9') v = v * 10 + c - '0'; vals[n++] = v; }
    else if (c == EOF) break;
  }
  int w = vals[0], h = vals[1];
  if (n < 2 || w <= 0 || h <= 0) { fprintf(stderr, "%s: bad PBM header\n", path); fclose(f); return -1; }
  if (!paper) paper = ufr2lt_paper_by_size(w * 72.0 / (600 * mult), h * 72.0 / 600, 3.0);
  if (!paper) paper = ufr2lt_paper_fitting(w * 72.0 / (600 * mult), h * 72.0 / 600);
  page_alloc(pg, paper, mult);
  size_t bpl = ((size_t)w + 7) / 8, cp = bpl < pg->stride ? bpl : pg->stride;
  uint8_t *row = malloc(bpl);
  for (int y = 0; y < h && y < paper->h_px; y++) {
    if (fread(row, 1, bpl, f) != bpl) break;
    memcpy(pg->bits + (size_t)y * pg->stride, row, cp);
  }
  free(row);
  fclose(f);
  return 0;
}

/* ------------------------------------------------------------------------ */

static const char *env(const char *name, const char *def) {
  const char *v = getenv(name);
  return v && *v ? v : def;
}

int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);                       /* a dropped connection is an error, not a crash */
  ufr2lt_job_opts_t o;
  ufr2lt_job_opts_init(&o);
  const char *outfile = NULL, *paper_name = NULL, *input = NULL;
  int pbm = 0, collate = 1, mult = 0, i;
  static char hostbuf[256] = "localhost", fullname[128];
  gethostname(hostbuf, sizeof(hostbuf));
  char *dot = strstr(hostbuf, ".local");
  if (dot) *dot = '\0';
  o.host_name = hostbuf;

  /* job metadata from ippeveprinter */
  o.job_name = env("IPP_JOB_NAME", env("IPP_DOCUMENT_NAME", "document"));
  o.doc_name = env("IPP_DOCUMENT_NAME", o.job_name);
  o.user_name = env("IPP_JOB_ORIGINATING_USER_NAME", env("IPP_REQUESTING_USER_NAME", NULL));
  if (o.user_name) {
    struct passwd *pw = getpwnam(o.user_name);     /* full name, as Canon's driver sends it */
    if (pw && pw->pw_gecos && *pw->pw_gecos) {
      snprintf(fullname, sizeof(fullname), "%.*s", (int)strcspn(pw->pw_gecos, ","), pw->pw_gecos);
      if (*fullname) o.user_name = fullname;
    }
  }
  o.copies = atoi(env("IPP_COPIES", "1"));
  const char *mdh = env("IPP_MULTIPLE_DOCUMENT_HANDLING", ""), *sc = env("IPP_SHEET_COLLATE", "");
  if (strstr(mdh, "uncollated") || !strcmp(sc, "uncollated")) collate = 0;
  const char *spm = getenv("UFR2LT_SPECIAL_PRINT_MODE");
  if (spm) o.special_print_mode = atoi(spm);
  const ufr2lt_paper_t *fallback = ufr2lt_paper_by_name(env("IPP_MEDIA", env("IPP_MEDIA_DEFAULT", NULL)));
  const char *device = env("UFR2LT_DEVICE", NULL);

  for (i = 1; i < argc && argv[i][0] == '-' && argv[i][1]; i++) {
    const char *a = argv[i];
#define NEXT (i + 1 < argc ? argv[++i] : (fprintf(stderr, "missing value for %s\n", a), exit(1), ""))
    if (!strcmp(a, "-o")) outfile = NEXT;
    else if (!strcmp(a, "--device")) device = NEXT;
    else if (!strcmp(a, "--find")) {               /* where is the printer? no data-port traffic */
      char addr[64], line[96];
      if (device_find(NEXT, addr, sizeof(addr))) { puts("missing"); return 1; }
      printf("%s %s\n", addr, device_status_line(addr, line, sizeof(line)) ? "unknown 0 0000 -1" : line);
      return 0;
    }
    else if (!strcmp(a, "--probe")) {              /* open the data port, send nothing */
      char addr[64] = "";
      int fd = device_open(NEXT, 0, addr, sizeof(addr));
      if (fd >= 0) device_close(fd);
      return fd < 0;
    }
    else if (!strcmp(a, "--title")) o.job_name = o.doc_name = NEXT;
    else if (!strcmp(a, "--user")) o.user_name = NEXT;
    else if (!strcmp(a, "--host")) o.host_name = NEXT;
    else if (!strcmp(a, "--copies")) o.copies = atoi(NEXT);
    else if (!strcmp(a, "--collate")) collate = 1;
    else if (!strcmp(a, "--no-collate")) collate = 0;
    else if (!strcmp(a, "--paper")) paper_name = NEXT;
    else if (!strcmp(a, "--hres")) mult = atoi(NEXT) == 2 ? 2 : 1;
    else if (!strcmp(a, "--special-mode")) o.special_print_mode = atoi(NEXT);
    else if (!strcmp(a, "--pbm")) pbm = 1;
    else if (!strcmp(a, "--time")) { double t = atof(NEXT); o.when = (time_t)t; o.when_ms = (int)lround((t - floor(t)) * 1000); }
    else if (!strcmp(a, "-v")) verbose = 1;
    else { fprintf(stderr, "unknown option %s\n", a); return 1; }
  }
  if (i < argc && !pbm) input = argv[i];
  if (pbm && !mult) mult = 1;
  if (o.copies < 1) o.copies = 1;
  if (o.special_print_mode < 0 || o.special_print_mode > 4) o.special_print_mode = 2;
  const ufr2lt_paper_t *forced = paper_name ? ufr2lt_paper_by_name(paper_name) : NULL;
  if (paper_name && !forced) { fprintf(stderr, "unknown paper %s\n", paper_name); return 1; }
  halftone_init();

  int outfd = 1;
  device_monitor_t *mon = NULL;
  if (device && !outfile) fprintf(stderr, "INFO: Printing \"%s\"\n", o.job_name);
  if (outfile) {
    if ((outfd = open(outfile, O_WRONLY | O_CREAT | O_TRUNC, 0644)) < 0) { perror(outfile); return 1; }
  } else if (device) {
    char addr[64] = "";
    if ((outfd = device_open(device, atoi(env("UFR2LT_RETRY", "900")), addr, sizeof(addr))) < 0) return 1;
    if (!getenv("UFR2LT_NO_SNMP")) mon = device_monitor_start(addr);
  }

  /* Collated multi-copy jobs are buffered and sent as repeated jobs (as Canon's driver does);
   * otherwise pages stream out as they are encoded, and the printer makes the copies. */
  int buffer_all = o.copies > 1 && collate;
  ufr2lt_page_t **pages = NULL;
  size_t npages = 0;
  ufr2lt_job_t *job = NULL;
  int rc = 0, pageno = 0;

#define EMIT(pgp) do {                                                            \
    ufr2lt_page_t *ep_ = (pgp);                                                    \
    if (buffer_all) {                                                              \
      pages = realloc(pages, (npages + 1) * sizeof(*pages));                       \
      pages[npages++] = ep_;                                                       \
    } else {                                                                       \
      if (!job) job = ufr2lt_job_new(&o, fd_write, &outfd);                        \
      if (ufr2lt_job_add_page(job, ep_) < 0) rc = 1;                               \
      ufr2lt_page_free(ep_);                                                       \
    }                                                                              \
  } while (0)

  if (pbm) {
    for (; i < argc && !rc; i++) {
      page_t pg = {0};
      if (pbm_page(argv[i], &pg, forced, mult) < 0) { rc = 1; break; }
      o.hres_mult = pg.mult;
      ufr2lt_page_t *ep = ufr2lt_page_encode(pg.bits, pg.stride, pg.paper, pg.mult);
      free(pg.bits);
      pageno++;
      EMIT(ep);
    }
  } else {
    int fd = input ? open(input, O_RDONLY) : 0;
    if (fd < 0) { perror(input); return 1; }
    cups_raster_t *ras = cupsRasterOpen(fd, CUPS_RASTER_READ);
    if (!ras) { fprintf(stderr, "ERROR: Input is not a raster stream\n"); return 1; }
    cups_page_header2_t h;
    while (!rc && cupsRasterReadHeader2(ras, &h)) {
      page_t pg = {0};
      if (raster_page(ras, &h, &pg, forced, fallback, mult) < 0) { rc = 1; free(pg.bits); break; }
      if (!pageno) o.hres_mult = pg.mult;           /* job-level resolution follows page 1 */
      ufr2lt_page_t *ep = ufr2lt_page_encode(pg.bits, pg.stride, pg.paper, pg.mult);
      free(pg.bits);
      pageno++;
      fprintf(stderr, "INFO: page %d encoded (%s, %zu bytes)\n", pageno, pg.paper->name, ufr2lt_page_size(ep));
      EMIT(ep);
    }
    cupsRasterClose(ras);
    if (fd) close(fd);
  }

  if (buffer_all && npages) {
    ufr2lt_job_opts_t jo = o;
    int repeats = 1;
    if (npages > 1) { jo.copies = 1; repeats = o.copies; }  /* one page: the printer makes the copies */
    for (int c = 0; c < repeats && !rc; c++) {
      job = ufr2lt_job_new(&jo, fd_write, &outfd);
      for (size_t k = 0; k < npages && !rc; k++) if (ufr2lt_job_add_page(job, pages[k]) < 0) rc = 1;
      if (!rc && ufr2lt_job_finish(job) < 0) rc = 1;
      ufr2lt_job_free(job);
      job = NULL;
    }
    for (size_t k = 0; k < npages; k++) ufr2lt_page_free(pages[k]);
  } else if (job) {
    if (ufr2lt_job_finish(job) < 0) rc = 1;
    ufr2lt_job_free(job);
  }
  free(pages);
  if (!pageno) fprintf(stderr, "INFO: No pages to print\n");
  if (outfile) close(outfd);
  else if (device) {
    int impressions = pageno * o.copies;
    if (device_close(outfd) < 0) rc = 1;
    if (mon) {
      if (!rc && impressions) fprintf(stderr, "INFO: Sent %d page(s); waiting for the printer to finish\n", impressions);
      device_monitor_finish(mon, rc ? 0 : impressions, 60 + 12 * impressions);
    }
  }
  return rc;
}
