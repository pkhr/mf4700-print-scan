/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * ufr2lt - open encoder for Canon "UFR II LT" laser printers (MF4700 series and
 * relatives), reverse-engineered from Canon's own driver output.
 *
 * Stream layout (see FORMAT.md):
 *   CPCA packets ("CD CA 10 kk", 20-byte header) carrying job/binder/document
 *   attributes, then data packets whose payload is a tagged binary page
 *   description: session -> paper group -> pages -> 256-line bands, each band an
 *   independent JBIG1 (T.82) stream (LRLTWO|TPBON, L0=128, MX=0).
 */
#ifndef UFR2LT_H
#define UFR2LT_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <time.h>

typedef struct {
  const char *name;     /* PPD-style name, e.g. "A4" */
  const char *pwg;      /* PWG 5101.1 media name, e.g. "iso_a4_210x297mm" */
  double w_pt, h_pt;    /* nominal size in points */
  uint8_t cpca_code;    /* CPCA document attribute 0x07ed */
  uint8_t pdl_code;     /* PDL paper attribute 0xc3 */
  uint16_t w_px, h_px;  /* page bitmap size at 600 dpi, as Canon's driver sends it */
} ufr2lt_paper_t;

extern const ufr2lt_paper_t ufr2lt_papers[];
extern const size_t ufr2lt_npapers;

const ufr2lt_paper_t *ufr2lt_paper_by_name(const char *name);  /* PPD or PWG name */
const ufr2lt_paper_t *ufr2lt_paper_by_size(double w_pt, double h_pt, double tol_pt);
const ufr2lt_paper_t *ufr2lt_paper_fitting(double w_pt, double h_pt); /* smallest that contains */

typedef ssize_t (*ufr2lt_write_cb)(void *ctx, const void *buf, size_t len);

typedef struct {
  const char *job_name;      /* CPCA 0x0004/0x082b, CP1252, max 32 bytes */
  const char *doc_name;      /* CPCA 0x0117, CP1252, max 255 bytes */
  const char *user_name;     /* CPCA 0x0006 (optional, NULL = omit), max 32 bytes */
  const char *host_name;     /* CPCA 0x0118, max 15 bytes */
  int copies;                /* uncollated copies, binder attribute 0x07d7 */
  int hres_mult;             /* 1 = 600x600 dpi, 2 = 1200x600 dpi */
  int special_print_mode;    /* 0x0971: 0=Off .. 4=Mode4; Canon default 2 */
  time_t when;               /* job timestamp (UTC); 0 = now */
  int when_ms;               /* milliseconds; -1 = now */
} ufr2lt_job_opts_t;

void ufr2lt_job_opts_init(ufr2lt_job_opts_t *o);

/* An encoded page: list of PDL chunks, each flushed as its own data packet group. */
typedef struct ufr2lt_page ufr2lt_page_t;

/*
 * Encode one page. bits: paper->h_px rows, stride bytes apart, each holding
 * paper->w_px * hres_mult pixels, MSB first, 1 = black.
 */
ufr2lt_page_t *ufr2lt_page_encode(const uint8_t *bits, size_t stride,
                                  const ufr2lt_paper_t *paper, int hres_mult);
size_t ufr2lt_page_size(const ufr2lt_page_t *p);
void ufr2lt_page_free(ufr2lt_page_t *p);

typedef struct ufr2lt_job ufr2lt_job_t;

ufr2lt_job_t *ufr2lt_job_new(const ufr2lt_job_opts_t *o, ufr2lt_write_cb cb, void *ctx);
int ufr2lt_job_add_page(ufr2lt_job_t *j, const ufr2lt_page_t *p); /* first call writes job header */
int ufr2lt_job_finish(ufr2lt_job_t *j);                            /* writes trailer */
int ufr2lt_job_pages(const ufr2lt_job_t *j);
void ufr2lt_job_free(ufr2lt_job_t *j);

#endif
