/* SPDX-License-Identifier: GPL-2.0-or-later */
/* device.h - printer connection (Bonjour/socket URIs) and SNMP status */
#ifndef DEVICE_H
#define DEVICE_H

#include <stddef.h>

/* Open a byte stream to the first reachable URI in a space/comma separated list
 * ("dnssd://CanonMF4700 socket://192.168.1.20:9100"), retrying for up to
 * retry_seconds. Returns a writable fd or -1; addr receives the printer's IPv4 address. */
int device_open(const char *uris, int retry_seconds, char *addr, size_t addrlen);

/* Finish sending: close fd and wait for the transport. Returns 0 on success. */
int device_close(int fd);

/* Locate a Canon printer without touching its data port (Bonjour + SNMP only,
 * so polling does not keep waking it). Returns 0 and fills addr when found. */
int device_find(const char *uris, char *addr, size_t addrlen);

/* SNMP status as "<state> <pages> <errorbits-hex>", e.g. "idle 18024 0000". */
int device_status_line(const char *addr, char *buf, size_t buflen);

typedef struct device_monitor device_monitor_t;

/* Poll the printer over SNMP and report problems as "STATE: +/-reason" lines. */
device_monitor_t *device_monitor_start(const char *addr);
/* Wait until `impressions` pages came out (or a timeout), then stop polling. */
void device_monitor_finish(device_monitor_t *m, int impressions, int timeout_s);

#endif
