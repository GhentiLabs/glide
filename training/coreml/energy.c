// Runs a command and prints the energy each SoC block used meanwhile, from IOReport's "Energy Model"
// counters (the same ones powermetrics reads), without sudo.
// Build: clang -O2 energy.c -o energy -framework CoreFoundation -lIOReport
// Use:   ./energy python bench.py ...      (with no command it measures 10 s of idle)
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

typedef struct IOReportSubscription *IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static double joules(int64_t v, CFStringRef unit) {
    char u[8] = "";
    if (unit) CFStringGetCString(unit, u, sizeof u, kCFStringEncodingUTF8);
    if (!strcmp(u, "mJ")) return v / 1e3;
    if (!strcmp(u, "uJ")) return v / 1e6;
    if (!strcmp(u, "nJ")) return v / 1e9;
    return -1;
}

int main(int argc, char **argv) {
    CFMutableDictionaryRef channels = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    CFMutableDictionaryRef subbed = NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, channels, &subbed, 0, NULL);
    if (!sub) { fprintf(stderr, "no IOReport subscription\n"); return 1; }

    CFDictionaryRef a = IOReportCreateSamples(sub, subbed, NULL);
    double t0 = now();
    int status = 0;
    if (argc > 1) {
        pid_t pid = fork();
        if (pid == 0) { execvp(argv[1], argv + 1); perror("exec"); _exit(127); }
        waitpid(pid, &status, 0);
    } else {
        sleep(10);
    }
    double seconds = now() - t0;
    CFDictionaryRef b = IOReportCreateSamples(sub, subbed, NULL);
    // IOReportCreateSamplesDelta returns zeros here, so subtract the cumulative counters directly.
    const char *keep[] = {"CPU Energy", "GPU Energy", "ANE", "DRAM", "GPU SRAM"};
    double total[5] = {0};
    CFArrayRef before = CFDictionaryGetValue(a, CFSTR("IOReportChannels"));
    CFArrayRef after = CFDictionaryGetValue(b, CFSTR("IOReportChannels"));
    for (CFIndex i = 0; i < CFArrayGetCount(after); i++) {
        CFDictionaryRef x = CFArrayGetValueAtIndex(before, i), y = CFArrayGetValueAtIndex(after, i);
        char name[64] = "";
        CFStringGetCString(IOReportChannelGetChannelName(y), name, sizeof name, kCFStringEncodingUTF8);
        int64_t used = IOReportSimpleGetIntegerValue(y, 0) - IOReportSimpleGetIntegerValue(x, 0);
        for (int k = 0; k < 5; k++)
            if (!strncmp(name, keep[k], strlen(keep[k])))
                total[k] += joules(used, IOReportChannelGetUnitLabel(y));
    }
    fprintf(stderr, "energy: %.2f s", seconds);
    for (int k = 0; k < 5; k++) fprintf(stderr, " | %s %.2f J", keep[k], total[k]);
    fprintf(stderr, "\n");
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
