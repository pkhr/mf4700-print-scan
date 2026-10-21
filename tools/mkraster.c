/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * mkraster - wrap 8-bit PGM pages (P5) into a PWG raster or Apple raster (URF)
 * stream, as an AirPrint client would send them. Test helper.
 *   mkraster pwg|urf iso_a4_210x297mm out.ras page1.pgm [page2.pgm ...]
 */
#include <cups/cups.h>
#include <cups/raster.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int pgm_header(FILE *f, int *w, int *h) {
  int vals[3], n = 0, c;
  if (getc(f) != 'P' || getc(f) != '5') return -1;
  while (n < 3 && (c = getc(f)) != EOF) {
    if (c == '#') { while ((c = getc(f)) != '\n' && c != EOF) {} continue; }
    if (c >= '0' && c <= '9') {
      int v = c - '0';
      while ((c = getc(f)) >= '0' && c <= '9') v = v * 10 + c - '0';
      vals[n++] = v;
    }
  }
  *w = vals[0]; *h = vals[1];
  return n == 3 && vals[2] == 255 ? 0 : -1;
}

int main(int argc, char **argv) {
  if (argc < 5) { fprintf(stderr, "usage: mkraster pwg|urf media out.ras page.pgm...\n"); return 1; }
  int apple = !strcmp(argv[1], "urf");
  pwg_media_t *media = pwgMediaForPWG(argv[2]);
  if (!media) { fprintf(stderr, "unknown media %s\n", argv[2]); return 1; }
  int fd = open(argv[3], O_WRONLY | O_CREAT | O_TRUNC, 0644);
  cups_raster_t *ras = cupsRasterOpen(fd, apple ? CUPS_RASTER_WRITE_APPLE : CUPS_RASTER_WRITE_PWG);
  for (int i = 4; i < argc; i++) {
    FILE *f = fopen(argv[i], "rb");
    int w, h;
    if (!f || pgm_header(f, &w, &h)) { fprintf(stderr, "%s: not an 8-bit PGM\n", argv[i]); return 1; }
    cups_page_header2_t hdr;
    cupsRasterInitPWGHeader(&hdr, media, "sgray_8", 600, 600, "one-sided", NULL);
    if ((int)hdr.cupsWidth != w || (int)hdr.cupsHeight != h)
      fprintf(stderr, "note: %s is %dx%d, media raster is %ux%u (cropped/padded)\n", argv[i], w, h, hdr.cupsWidth, hdr.cupsHeight);
    hdr.cupsInteger[0] = argc - 4;                  /* total page count (Apple raster) */
    cupsRasterWriteHeader2(ras, &hdr);
    unsigned char *line = malloc(hdr.cupsBytesPerLine), *in = malloc(w);
    for (unsigned y = 0; y < hdr.cupsHeight; y++) {
      memset(line, 255, hdr.cupsBytesPerLine);
      if ((int)y < h && fread(in, 1, w, f) == (size_t)w)
        memcpy(line, in, (unsigned)w < hdr.cupsWidth ? (size_t)w : hdr.cupsWidth);
      cupsRasterWritePixels(ras, line, hdr.cupsBytesPerLine);
    }
    free(line); free(in); fclose(f);
  }
  cupsRasterClose(ras);
  close(fd);
  return 0;
}
