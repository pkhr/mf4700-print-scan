# SPDX-License-Identifier: GPL-2.0-or-later
# mf4700-print-scan: open UFR II LT encoder, MFNP scan client and a self-contained print & scan app for Canon MF4700-series printers
CC       ?= clang
ARCHS    ?= -arch arm64 -arch x86_64
CFLAGS   ?= -O2 -Wall -Wextra -Wno-unused-parameter

VENDOR = vendor/jbigkit/jbig.c vendor/jbigkit/jbig_ar.c
SRCS   = src/rastertoufr2lt.c src/ufr2lt.c src/device.c

all: rastertoufr2lt mfnpscan

rastertoufr2lt: $(SRCS) src/ufr2lt.h src/device.h $(VENDOR)
	$(CC) $(ARCHS) -O2 -w -c vendor/jbigkit/jbig.c -o jbig.o
	$(CC) $(ARCHS) -O2 -w -c vendor/jbigkit/jbig_ar.c -o jbig_ar.o
	$(CC) $(ARCHS) $(CFLAGS) -o $@ $(SRCS) jbig.o jbig_ar.o -lcups
	rm -f jbig.o jbig_ar.o

mfnpscan: src/mfnpscan.c
	$(CC) $(ARCHS) $(CFLAGS) -o $@ src/mfnpscan.c

test: rastertoufr2lt
	./test/run-tests.sh


clean:
	rm -f rastertoufr2lt mfnpscan *.o

.PHONY: all test clean
