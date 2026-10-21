/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * ufr2lt.c - Canon UFR II LT encoder. See ufr2lt.h and FORMAT.md.
 */
#include "ufr2lt.h"
#include "../vendor/jbigkit/jbig.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <math.h>
#include <sys/time.h>

/* ------------------------------------------------------------------------ */
/* Paper table, measured from Canon's driver (CNPZBMF4700ZB.ppd).            */
/* ------------------------------------------------------------------------ */

const ufr2lt_paper_t ufr2lt_papers[] = {
  /* name                    pwg                              w_pt     h_pt    cpca  pdl   w_px  h_px */
  { "A4",                    "iso_a4_210x297mm",              595.28,  841.89, 0x02, 0x00, 4958, 7016 },
  { "Letter",                "na_letter_8.5x11in",            612.00,  792.00, 0x0d, 0x64, 5100, 6600 },
  { "Legal",                 "na_legal_8.5x14in",             612.00, 1008.00, 0x0c, 0x66, 5100, 8400 },
  { "A5",                    "iso_a5_148x210mm",              419.53,  595.28, 0x03, 0x02, 3499, 4958 },
  { "B5",                    "jis_b5_182x257mm",              515.91,  728.50, 0x07, 0x0b, 4299, 6074 },
  { "Executive",             "na_executive_7.25x10.5in",      522.00,  756.00, 0x0a, 0x65, 4350, 6300 },
  { "Statement",             "na_invoice_5.5x8.5in",          396.00,  612.00, 0x3c, 0x6b, 3300, 5100 },
  { "Postcard",              "jpn_hagaki_100x148mm",          283.46,  419.53, 0x0e, 0x14, 2358, 3499 },
  { "DoublePostcardRotated", "jpn_oufuku_148x200mm",          419.53,  566.93, 0x0f, 0x15, 3499, 4724 },
  { "200x297mm",             "om_4-on-1-postcard_200x297mm",  566.93,  841.89, 0x37, 0x16, 4724, 7016 },
  { "EnvChou3",              "jpn_chou3_120x235mm",           340.16,  666.14, 0xc1, 0x22, 2833, 5550 },
  { "120x235mm",             "om_yougata-naga3_120x235mm",    340.16,  666.14, 0xd5, 0x28, 2833, 5550 },
  { "EnvMonarch",            "na_monarch_3.875x7.5in",        279.00,  540.00, 0x17, 0x24, 2316, 4491 },
  { "Env10",                 "na_number-10_4.125x9.5in",      297.00,  684.00, 0x16, 0x23, 2483, 5691 },
  { "EnvDL",                 "iso_dl_110x220mm",              311.81,  623.62, 0x18, 0x27, 2599, 5199 },
  { "EnvC5",                 "iso_c5_162x229mm",              459.21,  649.13, 0x15, 0x25, 3824, 5408 },
  { "3x5",                   "na_index-3x5_3x5in",            216.00,  360.00, 0x40, 0x73, 1800, 3000 },
  { "216x318mm",             "om_oficio_216x318mm",           612.28,  901.42, 0x3e, 0x71, 5100, 7508 },
  { "216x356mm",             "om_brazil-oficio_216x356mm",    612.28, 1009.13, 0xcc, 0x60, 5100, 8383 },
  { "216x341mm",             "om_mexico-oficio_216x341mm",    612.28,  966.61, 0xd2, 0x62, 5100, 8058 },
  { "203x267mm",             "om_govt-letter_203x267mm",      575.43,  756.85, 0xd0, 0x5a, 4791, 6308 },
  { "203x330mm",             "na_govt-legal_8x13in",          575.43,  935.43, 0xd1, 0x5c, 4791, 7791 },
  { "195x270mm",             "om_16k_195x270mm",              552.76,  765.35, 0xd4, 0x78, 4608, 6374 },
  { "216x330mm",             "na_foolscap_8.5x13in",          612.28,  935.43, 0x3d, 0x70, 5100, 7791 },
  { "206x337mm",             "om_australia-foolscap_206x337mm", 583.94, 955.28, 0xca, 0x63, 4866, 7958 },
};
const size_t ufr2lt_npapers = sizeof(ufr2lt_papers) / sizeof(ufr2lt_papers[0]);

const ufr2lt_paper_t *ufr2lt_paper_by_name(const char *name) {
  if (!name) return NULL;
  for (size_t i = 0; i < ufr2lt_npapers; i++)
    if (!strcasecmp(name, ufr2lt_papers[i].name) || !strcmp(name, ufr2lt_papers[i].pwg))
      return &ufr2lt_papers[i];
  return NULL;
}

const ufr2lt_paper_t *ufr2lt_paper_by_size(double w, double h, double tol) {
  const ufr2lt_paper_t *best = NULL;
  double bestd = tol;
  for (size_t i = 0; i < ufr2lt_npapers; i++) {
    double d = fmax(fabs(ufr2lt_papers[i].w_pt - w), fabs(ufr2lt_papers[i].h_pt - h));
    if (d <= bestd) { bestd = d; best = &ufr2lt_papers[i]; }
  }
  return best;
}

const ufr2lt_paper_t *ufr2lt_paper_fitting(double w, double h) {
  const ufr2lt_paper_t *best = NULL;
  for (size_t i = 0; i < ufr2lt_npapers; i++) {
    const ufr2lt_paper_t *p = &ufr2lt_papers[i];
    if (p->w_pt + 2 >= w && p->h_pt + 2 >= h && (!best || p->w_pt * p->h_pt < best->w_pt * best->h_pt))
      best = p;
  }
  return best ? best : &ufr2lt_papers[0];
}

/* ------------------------------------------------------------------------ */
/* Growable byte buffer                                                      */
/* ------------------------------------------------------------------------ */

typedef struct { uint8_t *d; size_t n, cap; } buf_t;

static void buf_put(buf_t *b, const void *p, size_t n) {
  if (b->n + n > b->cap) {
    b->cap = (b->n + n) * 2 + 256;
    b->d = realloc(b->d, b->cap);
    if (!b->d) { perror("ufr2lt: realloc"); exit(2); }
  }
  memcpy(b->d + b->n, p, n);
  b->n += n;
}
static void buf_u8(buf_t *b, unsigned v) { uint8_t c = (uint8_t)v; buf_put(b, &c, 1); }
static void buf_u16(buf_t *b, unsigned v) { buf_u8(b, v >> 8); buf_u8(b, v); }
static void buf_u32(buf_t *b, uint32_t v) { buf_u16(b, v >> 16); buf_u16(b, v & 0xffff); }

/* ------------------------------------------------------------------------ */
/* PDL token writers (tag >= 0xc0, type 0x80..0xbf, immediate < 0x80)        */
/* ------------------------------------------------------------------------ */

static void pdl_imm(buf_t *b, unsigned tag, unsigned v) { buf_u8(b, tag); buf_u8(b, v & 0x7f); }
static void pdl_u8(buf_t *b, unsigned tag, unsigned v) { buf_u8(b, tag); buf_u8(b, 0x80); buf_u8(b, v); }
static void pdl_u16(buf_t *b, unsigned tag, unsigned v) { buf_u8(b, tag); buf_u8(b, 0x84); buf_u16(b, v); }
static void pdl_u16x2(buf_t *b, unsigned tag, unsigned x, unsigned y) {
  buf_u8(b, tag); buf_u8(b, 0x85); buf_u16(b, x); buf_u16(b, y);
}
static void pdl_xy(buf_t *b, unsigned tag, int x, int y) {      /* signed pair, smallest width */
  buf_u8(b, tag);
  if (x >= -128 && x < 128 && y >= -128 && y < 128) { buf_u8(b, 0xa1); buf_u8(b, x); buf_u8(b, y); }
  else { buf_u8(b, 0xa5); buf_u16(b, x & 0xffff); buf_u16(b, y & 0xffff); }
}
static void pdl_slen(buf_t *b, unsigned tag, uint32_t n) {     /* signed scalar, smallest width */
  buf_u8(b, tag);
  if (n < 0x80) { buf_u8(b, 0xa0); buf_u8(b, n); }
  else if (n < 0x8000) { buf_u8(b, 0xa4); buf_u16(b, n); }
  else { buf_u8(b, 0xa8); buf_u32(b, n); }
}
static void pdl_block(buf_t *b, const uint8_t *p, size_t n) {   /* length-prefixed data block */
  if (n < 0x100) { buf_u8(b, 0x9c); buf_u8(b, n); }
  else if (n < 0x10000) { buf_u8(b, 0x9d); buf_u16(b, n); }
  else { buf_u8(b, 0x9e); buf_u32(b, (uint32_t)n); }
  buf_put(b, p, n);
}

/* ------------------------------------------------------------------------ */
/* JBIG band encoding                                                        */
/* ------------------------------------------------------------------------ */

#define BAND_LINES 256
#define JBIG_L0    128

static void jbig_sink(unsigned char *start, size_t len, void *file) { buf_put(file, start, len); }

/* Encode rows as an independent JBIG BIE; returns BIE (BIH + SDE) in out. */
static void jbig_band(buf_t *out, const uint8_t *rows, size_t stride, unsigned w, unsigned h) {
  size_t bpl = (w + 7) / 8;
  uint8_t *plane = NULL;
  const uint8_t *src = rows;
  if (stride != bpl) {                     /* jbigkit wants packed rows */
    plane = malloc(bpl * h);
    for (unsigned y = 0; y < h; y++) memcpy(plane + y * bpl, rows + y * stride, bpl);
    src = plane;
  }
  unsigned char *planes[1] = { (unsigned char *)src };
  struct jbg_enc_state se;
  jbg_enc_init(&se, w, h, 1, planes, jbig_sink, out);
  jbg_enc_options(&se, 0, JBG_LRLTWO | JBG_TPBON, JBIG_L0, 0, 0);
  jbg_enc_out(&se);
  jbg_enc_free(&se);
  free(plane);
  /* Each band ends with SDRST instead of SDNORM: the printer resets per band. */
  if (out->n >= 22 && out->d[out->n - 2] == 0xff && out->d[out->n - 1] == 0x02)
    out->d[out->n - 1] = 0x03;
}

/* ------------------------------------------------------------------------ */
/* Pages                                                                     */
/* ------------------------------------------------------------------------ */

struct ufr2lt_page {
  const ufr2lt_paper_t *paper;
  int hres_mult;
  size_t nchunks;
  buf_t *chunks;      /* [0] = page begin, [1..] = bands, [last] = end page */
};

static buf_t *page_chunk(ufr2lt_page_t *p) {
  p->chunks = realloc(p->chunks, (p->nchunks + 1) * sizeof(buf_t));
  memset(&p->chunks[p->nchunks], 0, sizeof(buf_t));
  return &p->chunks[p->nchunks++];
}

ufr2lt_page_t *ufr2lt_page_encode(const uint8_t *bits, size_t stride,
                                  const ufr2lt_paper_t *paper, int hres_mult) {
  ufr2lt_page_t *p = calloc(1, sizeof(*p));
  p->paper = paper;
  p->hres_mult = hres_mult < 2 ? 1 : 2;
  unsigned W = paper->w_px, H = paper->h_px, xd = W * p->hres_mult;

  buf_t *c = page_chunk(p);                         /* begin page */
  buf_u8(c, 0x03);
  pdl_u16x2(c, 0xe7, W, H);
  pdl_u8(c, 0xde, 0);
  pdl_imm(c, 0xc8, 0);
  pdl_xy(c, 0xca, 0, 0);
  pdl_imm(c, 0xcb, 0);

  buf_t bie = {0};
  for (unsigned y = 0; y < H; y += BAND_LINES) {
    unsigned bh = H - y < BAND_LINES ? H - y : BAND_LINES;
    bie.n = 0;
    jbig_band(&bie, bits + (size_t)y * stride, stride, xd, bh);
    const uint8_t *data = bie.d;
    size_t n = bie.n;
    if (y == 0) {                                   /* keep BIH, but with the page height */
      bie.d[8] = H >> 24; bie.d[9] = H >> 16; bie.d[10] = H >> 8; bie.d[11] = H;
    } else {
      data += 20; n -= 20;
    }
    c = page_chunk(p);
    if (y == 0) {                                   /* begin image */
      buf_u8(c, 0x61);
      pdl_u8(c, 0xe6, p->hres_mult);
      pdl_imm(c, 0xe5, 0);
    }
    buf_u8(c, 0x62);                                /* band */
    pdl_u16x2(c, 0xe3, W, bh);
    pdl_xy(c, 0xe8, 0, (int)y);
    pdl_imm(c, 0xe1, 5);                            /* compression: JBIG */
    pdl_slen(c, 0xd7, (uint32_t)n);
    pdl_block(c, data, n);
  }
  free(bie.d);

  c = page_chunk(p);                                /* end page */
  buf_u8(c, 0x13);
  return p;
}

size_t ufr2lt_page_size(const ufr2lt_page_t *p) {
  size_t n = 0;
  for (size_t i = 0; i < p->nchunks; i++) n += p->chunks[i].n;
  return n;
}

void ufr2lt_page_free(ufr2lt_page_t *p) {
  if (!p) return;
  for (size_t i = 0; i < p->nchunks; i++) free(p->chunks[i].d);
  free(p->chunks);
  free(p);
}

/* ------------------------------------------------------------------------ */
/* CPCA job framing                                                          */
/* ------------------------------------------------------------------------ */

enum {
  CPCA_JOB_ATTR = 0x12, CPCA_JOB_END = 0x13, CPCA_BINDER_START = 0x14, CPCA_BINDER_ATTR = 0x15,
  CPCA_BINDER_END = 0x16, CPCA_DOC_START = 0x17, CPCA_DOC_ATTR = 0x18, CPCA_DOC_END = 0x19,
  CPCA_DATA = 0x1a, CPCA_JOB_START = 0x6b,
};
#define DATA_MAX 4075   /* payload bytes per data packet after the 0x01 lead byte */

/* Driver identifier Canon's libcoral.dylib places in job attribute 0x0118. */
static const uint8_t canon_driver_id[16] = {
  0x8b, 0xf2, 0x3a, 0x27, 0x2e, 0x1e, 0x44, 0xd4, 0xb2, 0x1f, 0x57, 0x32, 0x97, 0xd7, 0x93, 0xab
};

struct ufr2lt_job {
  ufr2lt_job_opts_t o;
  ufr2lt_write_cb cb;
  void *ctx;
  int failed, started, pages;
  const ufr2lt_paper_t *paper;   /* current paper group */
  uint64_t written;
};

static void job_write(ufr2lt_job_t *j, const void *p, size_t n) {
  const uint8_t *s = p;
  while (n && !j->failed) {
    ssize_t r = j->cb(j->ctx, s, n);
    if (r <= 0) { j->failed = 1; break; }
    s += r; n -= (size_t)r; j->written += (uint64_t)r;
  }
}

static void cpca_packet(ufr2lt_job_t *j, int kind, unsigned op, const void *payload, size_t n) {
  uint8_t h[20] = { 0xcd, 0xca, 0x10, (uint8_t)kind, (uint8_t)(op >> 8), (uint8_t)op, 0x00, 0x01,
                    (uint8_t)(n >> 8), (uint8_t)n, 0xff, 0xff };
  job_write(j, h, sizeof(h));
  if (n) job_write(j, payload, n);
}

static void cpca_buf(ufr2lt_job_t *j, unsigned op, buf_t *b) {
  cpca_packet(j, 0, op, b->d, b->n);
  b->n = 0;
}

static void cpca_data_chunk(ufr2lt_job_t *j, const uint8_t *p, size_t n) {
  uint8_t pkt[1 + DATA_MAX];
  pkt[0] = 0x01;
  do {
    size_t k = n > DATA_MAX ? DATA_MAX : n;
    memcpy(pkt + 1, p, k);
    cpca_packet(j, 2, CPCA_DATA, pkt, 1 + k);
    p += k; n -= k;
  } while (n);
}

/* UTF-8 -> Windows-1252, unmappable characters become '?' (as Canon does). */
static size_t to_cp1252(const char *s, uint8_t *out, size_t max) {
  static const uint16_t hi[32] = {
    0x20ac, 0, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021, 0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017d, 0,
    0, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0, 0x017e, 0x0178 };
  const uint8_t *u = (const uint8_t *)(s ? s : "");
  size_t n = 0;
  while (*u && n < max) {
    uint32_t cp; int len;
    if (*u < 0x80) { cp = *u; len = 1; }
    else if ((*u & 0xe0) == 0xc0 && (u[1] & 0xc0) == 0x80) { cp = ((*u & 0x1fu) << 6) | (u[1] & 0x3f); len = 2; }
    else if ((*u & 0xf0) == 0xe0 && (u[1] & 0xc0) == 0x80 && (u[2] & 0xc0) == 0x80) {
      cp = ((*u & 0x0fu) << 12) | ((u[1] & 0x3fu) << 6) | (u[2] & 0x3f); len = 3;
    } else if ((*u & 0xf8) == 0xf0 && (u[1] & 0xc0) == 0x80 && (u[2] & 0xc0) == 0x80 && (u[3] & 0xc0) == 0x80) {
      cp = 0x10000; len = 4;
    } else { cp = '?'; len = 1; }
    uint8_t ch = '?';
    if (cp < 0x80 || (cp >= 0xa0 && cp <= 0xff)) ch = (uint8_t)cp;
    else for (int k = 0; k < 32; k++) if (hi[k] && hi[k] == cp) { ch = (uint8_t)(0x80 + k); break; }
    out[n++] = ch;
    u += len;
  }
  return n;
}

/* CPCA string: charset (MIBenum 4 = ISO-8859-1), length byte, bytes. */
static void cpca_str(buf_t *b, const char *s, size_t max) {
  uint8_t tmp[256];
  size_t n = to_cp1252(s, tmp, max);
  buf_u16(b, 0x0004);
  buf_u8(b, n);
  buf_put(b, tmp, n);
}

static void tlv_str(buf_t *b, unsigned id, const char *s, size_t max) {
  buf_t v = {0};
  cpca_str(&v, s, max);
  buf_u16(b, id); buf_u16(b, v.n); buf_put(b, v.d, v.n);
  free(v.d);
}

static void job_header(ufr2lt_job_t *j, const ufr2lt_paper_t *paper) {
  const ufr2lt_job_opts_t *o = &j->o;
  buf_t b = {0};

  /* --- job start: TLV list --- */
  struct timeval tv; gettimeofday(&tv, NULL);
  time_t when = o->when ? o->when : tv.tv_sec;
  int ms = o->when_ms >= 0 ? o->when_ms : (int)(tv.tv_usec / 1000);
  struct tm tm; gmtime_r(&when, &tm);
  int have_user = o->user_name && *o->user_name;

  buf_u16(&b, have_user ? 9 : 8);
  buf_u16(&b, 0x00f0); buf_u16(&b, 1); buf_u8(&b, 0x01);
  buf_u16(&b, 0x0130); buf_u16(&b, 3); buf_u8(&b, 0x03); buf_u16(&b, 0x0000);
  tlv_str(&b, 0x0004, o->job_name, 32);
  tlv_str(&b, 0x0117, o->doc_name ? o->doc_name : o->job_name, 255);
  if (have_user) tlv_str(&b, 0x0006, o->user_name, 32);
  buf_u16(&b, 0x000d); buf_u16(&b, 1); buf_u8(&b, 0x04);
  buf_u16(&b, 0x0118); buf_u16(&b, 64);
  buf_put(&b, canon_driver_id, 16);
  uint8_t host[16] = {0}, zero[16] = {0};
  to_cp1252(o->host_name, host, 15);
  buf_put(&b, zero, 16); buf_put(&b, host, 16); buf_put(&b, host, 16);
  buf_u16(&b, 0x000c); buf_u16(&b, 1); buf_u8(&b, 0x32);
  buf_u16(&b, 0x0009); buf_u16(&b, 8);
  buf_u32(&b, ((uint32_t)(tm.tm_year + 1900) << 20) | ((uint32_t)(tm.tm_mon + 1) << 16) |
              ((uint32_t)tm.tm_mday << 11) | ((uint32_t)tm.tm_wday << 8));
  buf_u8(&b, tm.tm_hour); buf_u8(&b, tm.tm_min); buf_u16(&b, tm.tm_sec * 1000 + ms);
  cpca_buf(j, CPCA_JOB_START, &b);

  buf_u16(&b, 0x07d7); buf_u16(&b, 1);                      cpca_buf(j, CPCA_JOB_ATTR, &b);
  buf_u32(&b, 0);                                           cpca_buf(j, CPCA_BINDER_START, &b);
  buf_u16(&b, 0x08b3); buf_u8(&b, 0x02);                    cpca_buf(j, CPCA_BINDER_ATTR, &b);
  buf_u16(&b, 0x082b); cpca_str(&b, o->job_name, 32);       cpca_buf(j, CPCA_BINDER_ATTR, &b);
  buf_u16(&b, 0x07d7); buf_u16(&b, o->copies);              cpca_buf(j, CPCA_BINDER_ATTR, &b);
  buf_u16(&b, 0x07d8); buf_u8(&b, 0x0f);                    cpca_buf(j, CPCA_BINDER_ATTR, &b);
  buf_u16(&b, 0x07d9); buf_u8(&b, 0x17); buf_u32(&b, 0);    cpca_buf(j, CPCA_BINDER_ATTR, &b);
  buf_u16(&b, 0x084a); buf_u8(&b, 0x04);                    cpca_buf(j, CPCA_BINDER_ATTR, &b);
  buf_u16(&b, 0x07da); buf_u8(&b, 0x00);                    cpca_buf(j, CPCA_BINDER_ATTR, &b);
  {
    static const uint8_t a8a5[13] = { 0xfe, 0xfe, 0xff, 0xfe, 0, 0, 0, 0, 0, 0, 0, 0, 0x03 };
    buf_u16(&b, 0x08a5); buf_put(&b, a8a5, 13);             cpca_buf(j, CPCA_BINDER_ATTR, &b);
  }
  buf_u32(&b, 0);                                           cpca_buf(j, CPCA_DOC_START, &b);
  buf_u16(&b, 0x002e); buf_u8(&b, 0x83); buf_u16(&b, 0);    cpca_buf(j, CPCA_DOC_ATTR, &b);
  buf_u16(&b, 0x08b5); buf_u8(&b, 0x02);                    cpca_buf(j, CPCA_DOC_ATTR, &b);
  buf_u16(&b, 0x086e); buf_u16(&b, 0x010b); buf_u16(&b, 0); cpca_buf(j, CPCA_DOC_ATTR, &b);
  {
    uint8_t ed[13] = { 0x03, 0xfe, 0x00, paper->cpca_code, 0, 0, 0, 0, 0, 0, 0, 0, 0x03 };
    buf_u16(&b, 0x07ed); buf_put(&b, ed, 13);               cpca_buf(j, CPCA_DOC_ATTR, &b);
  }
  buf_u16(&b, 0x07d7); buf_u16(&b, 1);                      cpca_buf(j, CPCA_DOC_ATTR, &b);
  buf_u16(&b, 0x07df); buf_u8(&b, 0x01);                    cpca_buf(j, CPCA_DOC_ATTR, &b);
  buf_u16(&b, 0x07e0); buf_u8(&b, 0x04);                    cpca_buf(j, CPCA_DOC_ATTR, &b);
  buf_u16(&b, 0x07e1); buf_u32(&b, 0);                      cpca_buf(j, CPCA_DOC_ATTR, &b);
  buf_u16(&b, 0x003a); buf_u8(&b, 0x08);
  buf_u16(&b, 600 * (o->hres_mult < 2 ? 1 : 2)); buf_u16(&b, 600);
                                                            cpca_buf(j, CPCA_DOC_ATTR, &b);
  buf_u16(&b, 0x0972); buf_u8(&b, 0x00);                    cpca_buf(j, CPCA_DOC_ATTR, &b);
  buf_u16(&b, 0x0971); buf_u8(&b, o->special_print_mode);   cpca_buf(j, CPCA_DOC_ATTR, &b);
  free(b.d);
}

/* Session + paper group header: emitted in front of the first page. */
static void pdl_session_begin(buf_t *c) {
  buf_u8(c, 0x01);
  pdl_u16x2(c, 0xc1, 0x1000, 0x1081);
  pdl_imm(c, 0xc2, 0);
  pdl_u16(c, 0xd8, 600);
  pdl_u8(c, 0xdd, 200);
  pdl_u16(c, 0xf0, 0x0800);
}

static void pdl_paper_begin(buf_t *c, const ufr2lt_paper_t *paper) {
  buf_u8(c, 0x02);
  pdl_imm(c, 0xc3, paper->pdl_code & 0x7f);
  pdl_imm(c, 0xc5, 0);
  pdl_imm(c, 0xc6, 0);
  buf_u8(c, 0x51);
  pdl_imm(c, 0xf2, 0);
}

void ufr2lt_job_opts_init(ufr2lt_job_opts_t *o) {
  memset(o, 0, sizeof(*o));
  o->job_name = "document";
  o->host_name = "localhost";
  o->copies = 1;
  o->hres_mult = 1;
  o->special_print_mode = 2;
  o->when_ms = -1;
}

ufr2lt_job_t *ufr2lt_job_new(const ufr2lt_job_opts_t *o, ufr2lt_write_cb cb, void *ctx) {
  ufr2lt_job_t *j = calloc(1, sizeof(*j));
  j->o = *o;
  if (j->o.copies < 1) j->o.copies = 1;
  if (j->o.copies > 999) j->o.copies = 999;
  j->cb = cb;
  j->ctx = ctx;
  return j;
}

int ufr2lt_job_add_page(ufr2lt_job_t *j, const ufr2lt_page_t *p) {
  buf_t head = {0};
  if (!j->started) {
    job_header(j, p->paper);
    pdl_session_begin(&head);
    pdl_paper_begin(&head, p->paper);
    j->paper = p->paper;
    j->started = 1;
  } else if (p->paper != j->paper) {                /* paper change: new paper group */
    buf_u8(&head, 0x12);
    pdl_paper_begin(&head, p->paper);
    j->paper = p->paper;
  }
  /* the page-begin chunk travels in the same packet as any session/paper header */
  buf_put(&head, p->chunks[0].d, p->chunks[0].n);
  cpca_data_chunk(j, head.d, head.n);
  free(head.d);
  for (size_t i = 1; i < p->nchunks; i++)
    cpca_data_chunk(j, p->chunks[i].d, p->chunks[i].n);
  j->pages++;
  return j->failed ? -1 : 0;
}

int ufr2lt_job_finish(ufr2lt_job_t *j) {
  if (!j->started) return -1;
  static const uint8_t end_session[2] = { 0x12, 0x11 };
  static const uint8_t one = 0x01;
  cpca_data_chunk(j, end_session, 2);
  cpca_packet(j, 0, CPCA_DATA, &one, 1);            /* end of data */
  cpca_packet(j, 0, CPCA_DOC_END, NULL, 0);
  buf_t b = {0};
  uint32_t impressions = (uint32_t)j->pages * (uint32_t)j->o.copies;
  buf_u16(&b, 0x0113); buf_u32(&b, impressions);    cpca_buf(j, CPCA_BINDER_ATTR, &b);
  cpca_packet(j, 0, CPCA_BINDER_END, NULL, 0);
  buf_u16(&b, 0x0113); buf_u32(&b, impressions);    cpca_buf(j, CPCA_JOB_ATTR, &b);
  /* total job size, counting this packet (26 bytes) and the job-end packet (21 bytes) */
  buf_u16(&b, 0x07d6); buf_u32(&b, (uint32_t)(j->written + 26 + 21));
                                                    cpca_buf(j, CPCA_JOB_ATTR, &b);
  buf_u8(&b, 0x00);                                 cpca_buf(j, CPCA_JOB_END, &b);
  free(b.d);
  return j->failed ? -1 : 0;
}

int ufr2lt_job_pages(const ufr2lt_job_t *j) { return j->pages; }

void ufr2lt_job_free(ufr2lt_job_t *j) { free(j); }
