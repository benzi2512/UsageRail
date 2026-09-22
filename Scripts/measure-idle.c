#include <errno.h>
#include <inttypes.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <unistd.h>

static int read_usage(pid_t pid, struct rusage_info_v4 *usage) {
    return proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)usage);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: measure-idle PID SECONDS\n");
        return 64;
    }
    char *end = NULL;
    long parsed_pid = strtol(argv[1], &end, 10);
    if (end == argv[1] || *end != '\0' || parsed_pid <= 0) return 64;
    long seconds = strtol(argv[2], &end, 10);
    if (end == argv[2] || *end != '\0' || seconds <= 0) return 64;

    struct rusage_info_v4 start = {0};
    struct rusage_info_v4 finish = {0};
    if (read_usage((pid_t)parsed_pid, &start) != 0) {
        perror("proc_pid_rusage(start)");
        return 1;
    }
    sleep((unsigned int)seconds);
    if (read_usage((pid_t)parsed_pid, &finish) != 0) {
        perror("proc_pid_rusage(finish)");
        return 1;
    }

    uint64_t cpu_ns = (finish.ri_user_time - start.ri_user_time)
        + (finish.ri_system_time - start.ri_system_time);
    uint64_t child_cpu_ns = (finish.ri_child_user_time - start.ri_child_user_time)
        + (finish.ri_child_system_time - start.ri_child_system_time);
    uint64_t wakeups = (finish.ri_interrupt_wkups - start.ri_interrupt_wkups)
        + (finish.ri_pkg_idle_wkups - start.ri_pkg_idle_wkups);
    uint64_t interrupt_wakeups = finish.ri_interrupt_wkups - start.ri_interrupt_wkups;
    uint64_t package_idle_wakeups = finish.ri_pkg_idle_wkups - start.ri_pkg_idle_wkups;
    double cpu_percent = ((double)cpu_ns / 1000000000.0) / (double)seconds * 100.0;
    double child_cpu_percent = ((double)child_cpu_ns / 1000000000.0) / (double)seconds * 100.0;
    double wakeups_per_minute = (double)wakeups / ((double)seconds / 60.0);
    double footprint_mb = (double)finish.ri_phys_footprint / 1000000.0;

    printf("{\"seconds\":%ld,\"averageCpuPercent\":%.4f,\"reapedChildCpuPercent\":%.4f,\"combinedCpuPercent\":%.4f,\"wakeupsPerMinute\":%.3f,\"interruptWakeups\":%" PRIu64 ",\"packageIdleWakeups\":%" PRIu64 ",\"physicalFootprintMB\":%.3f}\n",
           seconds, cpu_percent, child_cpu_percent, cpu_percent + child_cpu_percent,
           wakeups_per_minute, interrupt_wakeups, package_idle_wakeups, footprint_mb);
    return 0;
}
