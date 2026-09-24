// probe: resource counters for each pid given, one key=value line per process.
// Times are printed raw - rusage and taskinfo count Mach ticks on Apple silicon - and
// `probe --selfcheck` burns 300 ms of CPU and prints the ratios report.py scales by.
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

typedef struct rusage_info_v6 usage_t;

static int usage(pid_t pid, usage_t *ri) {
    return proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)ri);
}

static int selfcheck(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    usage_t a, b;
    usage(getpid(), &a);
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), t1;
    volatile uint64_t spin = 0;
    while ((t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) - t0 < 300000000ull) spin++;
    usage(getpid(), &b);
    double raw = (double)(b.ri_user_time - a.ri_user_time + b.ri_system_time - a.ri_system_time);
    double wall = (double)(t1 - t0);
    printf("selfcheck numer=%u denom=%u raw_ratio=%.4f scaled_ratio=%.4f\n", tb.numer, tb.denom,
           raw / wall, raw * tb.numer / tb.denom / wall);
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--selfcheck") == 0) return selfcheck();
    for (int i = 1; i < argc; i++) {
        pid_t pid = (pid_t)atoi(argv[i]);
        usage_t ri;
        struct proc_taskinfo ti;
        if (usage(pid, &ri) != 0 ||
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof ti) != (int)sizeof ti) {
            printf("pid=%d error=1\n", pid);
            continue;
        }
        printf("pid=%d user=%llu sys=%llu user_p=%llu sys_p=%llu "
               "qos_def=%llu qos_mnt=%llu qos_bg=%llu qos_ut=%llu qos_leg=%llu qos_in=%llu qos_ui=%llu "
               "intr_wkups=%llu idle_wkups=%llu footprint=%llu peak_footprint=%llu "
               "instructions=%llu cycles=%llu energy_nj=%llu "
               "mach_sc=%d unix_sc=%d csw=%d faults=%d msgs_sent=%d msgs_recv=%d threads=%d\n",
               pid, ri.ri_user_time, ri.ri_system_time, ri.ri_user_ptime, ri.ri_system_ptime,
               ri.ri_cpu_time_qos_default, ri.ri_cpu_time_qos_maintenance, ri.ri_cpu_time_qos_background,
               ri.ri_cpu_time_qos_utility, ri.ri_cpu_time_qos_legacy, ri.ri_cpu_time_qos_user_initiated,
               ri.ri_cpu_time_qos_user_interactive,
               ri.ri_interrupt_wkups, ri.ri_pkg_idle_wkups, ri.ri_phys_footprint,
               ri.ri_lifetime_max_phys_footprint, ri.ri_instructions, ri.ri_cycles, ri.ri_energy_nj,
               ti.pti_syscalls_mach, ti.pti_syscalls_unix, ti.pti_csw, ti.pti_faults,
               ti.pti_messages_sent, ti.pti_messages_received, ti.pti_threadnum);
    }
    return 0;
}
