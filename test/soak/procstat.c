/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * procstat - resource use of a process tree, for the soak test.
 *   procstat PID   one line per process in PID's tree:
 *   pid ppid depth footprint_kb resident_kb threads cpu_ms fds zombie peak_kb name
 */
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>

static double ticks_to_ms(uint64_t t) {
  static mach_timebase_info_data_t tb;
  if (!tb.denom) mach_timebase_info(&tb);
  return (double)t * tb.numer / tb.denom / 1e6;
}

static void show(pid_t pid, int depth) {
  struct kinfo_proc kp;
  size_t len = sizeof(kp);
  int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
  if (sysctl(mib, 4, &kp, &len, NULL, 0) || !len) return;
  int zombie = kp.kp_proc.p_stat == SZOMB;
  struct rusage_info_v4 ru = {0};
  struct proc_taskinfo ti = {0};
  int fds = -1;
  if (!zombie) {
    proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ru);
    proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof(ti));
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes > 0) {
      struct proc_fdinfo *fd = malloc((size_t)bytes);
      bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fd, bytes);
      fds = bytes / (int)sizeof(struct proc_fdinfo);
      free(fd);
    }
  }
  printf("%d %d %d %llu %llu %d %.0f %d %d %llu %s\n", pid, kp.kp_eproc.e_ppid, depth,
         (unsigned long long)ru.ri_phys_footprint / 1024, (unsigned long long)ti.pti_resident_size / 1024,
         ti.pti_threadnum, ticks_to_ms(ru.ri_user_time + ru.ri_system_time), fds, zombie,
         (unsigned long long)ru.ri_lifetime_max_phys_footprint / 1024, kp.kp_proc.p_comm);
  pid_t kids[256];
  int n = proc_listchildpids(pid, kids, sizeof(kids)) ;
  for (int i = 0; i < n && i < 256; i++) show(kids[i], depth + 1);
}

int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) show(atoi(argv[i]), 0);
  return 0;
}
