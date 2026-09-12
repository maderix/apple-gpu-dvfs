// gpu_freq_ctl — Control Apple Silicon GPU frequency via direct AGX power cap
//
// Primary: SetMaxGPUAbsolutePower on AGX driver (M1–M5, GPU-only, instant)
// Fallback: CLPC pkg-low-power-target (system-wide, has PID lag)
//
// Build:
//   xcrun clang -framework IOKit -framework Foundation -framework Metal -O2 \
//     -o gpu_freq_ctl gpu_freq_ctl.m
//
// Usage:
//   sudo ./gpu_freq_ctl status          Show current state + measured GPU speed
//   sudo ./gpu_freq_ctl cap <watts>     Cap GPU power (e.g. 5 = 5W)
//   sudo ./gpu_freq_ctl uncap           Restore original power cap
//   sudo ./gpu_freq_ctl sweep           Sweep power levels, measure GFLOPS
//   ./gpu_freq_ctl table                Print DVFS P-state table (no sudo)
//   ./gpu_freq_ctl info                 Show detected SoC + GPU info (no sudo)
//
// Flags:
//   -v / --verbose       Verbose output (show IOKit calls, raw values)
//   --confirm            After cap/uncap, run powermetrics to confirm frequency
//   --no-burn            Skip burn-in during cap (faster but less reliable)
//   --clpc              Force CLPC fallback path instead of AGX

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/sysctl.h>

// ─── Terminal colors ────────────────────────────────────────────────────────

#define C_RESET   "\033[0m"
#define C_BOLD    "\033[1m"
#define C_DIM     "\033[2m"
#define C_RED     "\033[31m"
#define C_GREEN   "\033[32m"
#define C_YELLOW  "\033[33m"
#define C_BLUE    "\033[34m"
#define C_CYAN    "\033[36m"

static int g_verbose = 0;
static int g_confirm = 0;
static int g_no_burn = 0;
static int g_force_clpc = 0;
static int g_color = 1;

#define LOG_INFO(fmt, ...)  printf("%s•%s " fmt "\n", g_color ? C_CYAN : "", g_color ? C_RESET : "", ##__VA_ARGS__)
#define LOG_OK(fmt, ...)    printf("%s✓%s " fmt "\n", g_color ? C_GREEN : "", g_color ? C_RESET : "", ##__VA_ARGS__)
#define LOG_WARN(fmt, ...)  printf("%s⚠%s " fmt "\n", g_color ? C_YELLOW : "", g_color ? C_RESET : "", ##__VA_ARGS__)
#define LOG_ERR(fmt, ...)   fprintf(stderr, "%s✗%s " fmt "\n", g_color ? C_RED : "", g_color ? C_RESET : "", ##__VA_ARGS__)
#define LOG_VERB(fmt, ...)  do { if (g_verbose) printf("%s  [v]%s " fmt "\n", g_color ? C_DIM : "", g_color ? C_RESET : "", ##__VA_ARGS__); } while(0)

// ─── SoC detection ──────────────────────────────────────────────────────────

typedef struct {
    char soc_name[32];
    char compatible[32];
    char clpc_class[64];
    char agx_class[64];
    int gpu_cores;
} SoCInfo;

static SoCInfo detect_soc(void) {
    SoCInfo info = {0};
    size_t len = sizeof(info.soc_name);
    sysctlbyname("machdep.cpu.brand_string", info.soc_name, &len, NULL, 0);

    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceNameMatching("sgx"), &iter);
    if (kr == KERN_SUCCESS) {
        io_service_t svc = IOIteratorNext(iter);
        if (svc) {
            CFTypeRef compat = IORegistryEntryCreateCFProperty(svc, CFSTR("compatible"), NULL, 0);
            if (compat && CFGetTypeID(compat) == CFDataGetTypeID()) {
                CFIndex clen = CFDataGetLength((CFDataRef)compat);
                if (clen < (CFIndex)sizeof(info.compatible))
                    CFDataGetBytes((CFDataRef)compat, CFRangeMake(0, clen), (UInt8 *)info.compatible);
            }
            if (compat) CFRelease(compat);
            IOObjectRelease(svc);
        }
        IOObjectRelease(iter);
    }

    if (strstr(info.compatible, "t8103")) snprintf(info.clpc_class, sizeof(info.clpc_class), "AppleT8103CLPC");
    else if (strstr(info.compatible, "t8112")) snprintf(info.clpc_class, sizeof(info.clpc_class), "AppleT8112CLPC");
    else if (strstr(info.compatible, "t8122")) snprintf(info.clpc_class, sizeof(info.clpc_class), "AppleT8122CLPC");
    else if (strstr(info.compatible, "t8132")) snprintf(info.clpc_class, sizeof(info.clpc_class), "AppleT8132CLPC");
    else snprintf(info.clpc_class, sizeof(info.clpc_class), "AppleCLPC");

    kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("AGXAccelerator"), &iter);
    if (kr == KERN_SUCCESS) {
        io_service_t svc = IOIteratorNext(iter);
        if (svc) {
            io_name_t cls;
            IOObjectGetClass(svc, cls);
            strlcpy(info.agx_class, cls, sizeof(info.agx_class));
            CFTypeRef cores = IORegistryEntryCreateCFProperty(svc, CFSTR("gpu-core-count"), NULL, 0);
            if (cores && CFGetTypeID(cores) == CFNumberGetTypeID()) {
                int32_t n = 0;
                CFNumberGetValue((CFNumberRef)cores, kCFNumberSInt32Type, &n);
                if (n > 0) info.gpu_cores = n;
            }
            if (cores) CFRelease(cores);
            IOObjectRelease(svc);
        }
        IOObjectRelease(iter);
    }
    return info;
}

// ─── AGX direct power cap (PRIMARY) ────────────────────────────────────────

static io_service_t g_agx = 0;

static io_service_t get_agx(void) {
    if (g_agx) return g_agx;
    const char *classes[] = {"AGXAcceleratorG16G", "AGXAcceleratorG17X",
                             "AGXAcceleratorG15X", "AGXAcceleratorG15G",
                             "AGXAcceleratorG14X", "AGXAcceleratorG13G",
                             "AGXAccelerator", NULL};
    for (int i = 0; classes[i]; i++) {
        g_agx = IOServiceGetMatchingService(kIOMainPortDefault,
            IOServiceMatching(classes[i]));
        if (g_agx) {
            LOG_VERB("Found AGX: %s", classes[i]);
            return g_agx;
        }
    }
    return 0;
}

static kern_return_t agx_set_power(int64_t milliwatts) {
    io_service_t agx = get_agx();
    if (!agx) return -1;
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(d, CFSTR("SetMaxGPUAbsolutePower"), kCFBooleanTrue);
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &milliwatts);
    CFDictionarySetValue(d, CFSTR("AbsoluteTarget"), n);
    kern_return_t kr = IORegistryEntrySetCFProperties(agx, d);
    CFRelease(n); CFRelease(d);
    LOG_VERB("agx_set_power(%lld mW) → 0x%x", milliwatts, kr);
    return kr;
}

static int64_t agx_get_max_power(void) {
    io_service_t agx = get_agx();
    if (!agx) return -1;
    CFTypeRef v = IORegistryEntryCreateCFProperty(agx, CFSTR("MaxGPUAbsolutePower"), NULL, 0);
    if (!v) return -1;
    int64_t r = 0;
    if (CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &r);
    CFRelease(v);
    return r;
}

static int64_t agx_get_filtered_power(void) {
    io_service_t agx = get_agx();
    if (!agx) return -1;
    CFTypeRef v = IORegistryEntryCreateCFProperty(agx, CFSTR("FilteredGPUPower"), NULL, 0);
    if (!v) return -1;
    int64_t r = 0;
    if (CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &r);
    CFRelease(v);
    return r;
}

static int agx_available(void) {
    if (g_force_clpc) return 0;
    io_service_t agx = get_agx();
    if (!agx) return 0;
    kern_return_t kr = agx_set_power(agx_get_max_power());
    return kr == KERN_SUCCESS;
}

// ─── State save/restore ────────────────────────────────────────────────────

static const char *STATEFILE = "/tmp/.gpu_freq_ctl_saved_state";

// v2 state: just the AGX max power (4 bytes magic + 8 bytes value)
#define STATE_MAGIC_AGX 0x41475832  // "AGX2"
#define STATE_MAGIC_CLPC 0x434C5043 // "CLPC"

typedef struct {
    uint32_t magic;
    int64_t agx_max_power;
} AGXSavedState;

// CLPC state (fallback)
typedef struct {
    int64_t pkg_avg_max_power;
    int64_t pkg_lowpeak_max_power;
    int64_t pkg_power_zone_target_0;
    int64_t pkg_power_zone_target_offset_0;
    int64_t pkg_power_split_gpu_fraction;
    int64_t pkg_power_split_cpu_fraction;
    int64_t pkg_power_split_ane_fraction;
    int64_t carplay_power_limit;
    int64_t pkg_low_power_target;
    int64_t pkg_avg_therm_power_target;
    int64_t pkg_avg_limiter_ki;
    int64_t pkg_avg_limiter_kp;
    int64_t pkg_lowpeak_limiter_ki;
    int64_t pkg_lowpeak_limiter_kp;
    int64_t cpu_avg_limiter_ki;
    int64_t cpu_avg_limiter_kp;
    int64_t cpu_lowpeak_limiter_ki;
    int64_t cpu_lowpeak_limiter_kp;
    int64_t cpu_rot_pwr_engage_thresh;
    int64_t cpu_rot_pwr_disengage_thresh;
} CLPCState;

typedef struct {
    uint32_t magic;
    CLPCState clpc;
} CLPCSavedState;

// ─── CLPC interface (FALLBACK) ─────────────────────────────────────────────

static io_service_t g_clpc = 0;

static io_service_t get_clpc(void) {
    if (g_clpc) return g_clpc;
    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("AppleCLPC"), &iter);
    if (kr != KERN_SUCCESS) return 0;
    g_clpc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    return g_clpc;
}

static kern_return_t clpc_set(const char *key, int64_t value) {
    io_service_t svc = get_clpc();
    if (!svc) return -1;
    CFStringRef cfKey = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFNumberRef cfVal = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
        NULL, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(dict, cfKey, cfVal);
    kern_return_t kr = IORegistryEntrySetCFProperties(svc, dict);
    CFRelease(dict); CFRelease(cfVal); CFRelease(cfKey);
    LOG_VERB("clpc_set(%s, %lld) → 0x%x", key, value, kr);
    return kr;
}

static int64_t clpc_get(const char *key) {
    io_service_t svc = get_clpc();
    if (!svc) return 0;
    CFStringRef cfKey = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef val = IORegistryEntryCreateCFProperty(svc, cfKey, NULL, 0);
    CFRelease(cfKey);
    if (!val) return 0;
    int64_t result = 0;
    if (CFGetTypeID(val) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)val, kCFNumberSInt64Type, &result);
    CFRelease(val);
    return result;
}

static CLPCState clpc_read_state(void) {
    CLPCState s;
    s.pkg_avg_max_power = clpc_get("~pkg-avg-max-power");
    s.pkg_lowpeak_max_power = clpc_get("~pkg-lowpeak-max-power");
    s.pkg_power_zone_target_0 = clpc_get("~pkg-power-zone-target-0");
    s.pkg_power_zone_target_offset_0 = clpc_get("~pkg-power-zone-target-offset-0");
    s.pkg_power_split_gpu_fraction = clpc_get("~pkg-power-split-gpu-fraction");
    s.pkg_power_split_cpu_fraction = clpc_get("~pkg-power-split-cpu-fraction");
    s.pkg_power_split_ane_fraction = clpc_get("~pkg-power-split-ane-fraction");
    s.carplay_power_limit = clpc_get("~carplay-power-limit");
    s.pkg_low_power_target = clpc_get("`pkg-low-power-target");
    s.pkg_avg_therm_power_target = clpc_get("`pkg-avg-therm-power-target");
    s.pkg_avg_limiter_ki = clpc_get("`pkg-avg-limiter-ki");
    s.pkg_avg_limiter_kp = clpc_get("`pkg-avg-limiter-kp");
    s.pkg_lowpeak_limiter_ki = clpc_get("`pkg-lowpeak-limiter-ki");
    s.pkg_lowpeak_limiter_kp = clpc_get("`pkg-lowpeak-limiter-kp");
    s.cpu_avg_limiter_ki = clpc_get("`cpu-avg-limiter-ki");
    s.cpu_avg_limiter_kp = clpc_get("`cpu-avg-limiter-kp");
    s.cpu_lowpeak_limiter_ki = clpc_get("`cpu-lowpeak-limiter-ki");
    s.cpu_lowpeak_limiter_kp = clpc_get("`cpu-lowpeak-limiter-kp");
    s.cpu_rot_pwr_engage_thresh = clpc_get("~cpu-rot-pwr-engage-thresh");
    s.cpu_rot_pwr_disengage_thresh = clpc_get("~cpu-rot-pwr-disengage-thresh");
    return s;
}

static void clpc_write_state(const CLPCState *s) {
    clpc_set("~pkg-avg-max-power", s->pkg_avg_max_power);
    clpc_set("~pkg-lowpeak-max-power", s->pkg_lowpeak_max_power);
    clpc_set("~pkg-power-zone-target-0", s->pkg_power_zone_target_0);
    clpc_set("~pkg-power-zone-target-offset-0", s->pkg_power_zone_target_offset_0);
    clpc_set("~pkg-power-split-gpu-fraction", s->pkg_power_split_gpu_fraction);
    clpc_set("~pkg-power-split-cpu-fraction", s->pkg_power_split_cpu_fraction);
    clpc_set("~pkg-power-split-ane-fraction", s->pkg_power_split_ane_fraction);
    clpc_set("~carplay-power-limit", s->carplay_power_limit);
    clpc_set("`pkg-low-power-target", s->pkg_low_power_target);
    clpc_set("`pkg-avg-therm-power-target", s->pkg_avg_therm_power_target);
    clpc_set("`pkg-avg-limiter-ki", s->pkg_avg_limiter_ki);
    clpc_set("`pkg-avg-limiter-kp", s->pkg_avg_limiter_kp);
    clpc_set("`pkg-lowpeak-limiter-ki", s->pkg_lowpeak_limiter_ki);
    clpc_set("`pkg-lowpeak-limiter-kp", s->pkg_lowpeak_limiter_kp);
    clpc_set("`cpu-avg-limiter-ki", s->cpu_avg_limiter_ki);
    clpc_set("`cpu-avg-limiter-kp", s->cpu_avg_limiter_kp);
    clpc_set("`cpu-lowpeak-limiter-ki", s->cpu_lowpeak_limiter_ki);
    clpc_set("`cpu-lowpeak-limiter-kp", s->cpu_lowpeak_limiter_kp);
    clpc_set("~cpu-rot-pwr-engage-thresh", s->cpu_rot_pwr_engage_thresh);
    clpc_set("~cpu-rot-pwr-disengage-thresh", s->cpu_rot_pwr_disengage_thresh);
}

// ─── GPU measurement ────────────────────────────────────────────────────────

static NSString *matmulShader = @
"#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void mm(device const float *A[[buffer(0)]],device const float *B[[buffer(1)]],"
"device float *C[[buffer(2)]],constant uint &N[[buffer(3)]],"
"uint2 g[[thread_position_in_grid]],uint2 l[[thread_position_in_threadgroup]]){"
"uint r=g.y,c=g.x;if(r>=N||c>=N)return;"
"threadgroup float As[16][16],Bs[16][16];float a=0;"
"for(uint t=0;t<(N+15)/16;t++){uint ac=t*16+l.x,br=t*16+l.y;"
"As[l.y][l.x]=(r<N&&ac<N)?A[r*N+ac]:0;Bs[l.y][l.x]=(br<N&&c<N)?B[br*N+c]:0;"
"threadgroup_barrier(mem_flags::mem_threadgroup);"
"for(uint i=0;i<16;i++)a=fma(As[l.y][i],Bs[i][l.x],a);"
"threadgroup_barrier(mem_flags::mem_threadgroup);}C[r*N+c]=a;}";

static double measure_gflops(void) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) return -1;
    NSError *err;
    id<MTLLibrary> lib = [dev newLibraryWithSource:matmulShader options:nil error:&err];
    if (!lib) return -1;
    id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:
        [lib newFunctionWithName:@"mm"] error:&err];
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    uint32_t N = 2048;
    id<MTLBuffer> A = [dev newBufferWithLength:N*N*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> B = [dev newBufferWithLength:N*N*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> C = [dev newBufferWithLength:N*N*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> Nb = [dev newBufferWithBytes:&N length:4 options:MTLResourceStorageModeShared];
    double best = 1e9;
    for (int r = 0; r < 5; r++) {
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:pso];
            [enc setBuffer:A offset:0 atIndex:0]; [enc setBuffer:B offset:0 atIndex:1];
            [enc setBuffer:C offset:0 atIndex:2]; [enc setBuffer:Nb offset:0 atIndex:3];
            [enc dispatchThreads:MTLSizeMake(N,N,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
            [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
            double ms = ([cb GPUEndTime] - [cb GPUStartTime]) * 1000.0;
            if (ms < best) best = ms;
        }
    }
    return 2.0 * N * N * N / (best * 1e6);
}

// Sustained-load burn-in: the AGX firmware only converges on a low power cap
// after several seconds of real GPU work. `cap` and `sweep` both use this so
// their numbers come from the same methodology (skip with --no-burn).
static void burn_in_gpu(double seconds) {
    if (g_no_burn) return;
    LOG_INFO("Burning in GPU for %.0fs (AGX firmware needs sustained load to converge)...", seconds);
    fflush(stdout);
    mach_timebase_info_data_t tbi;
    mach_timebase_info(&tbi);
    uint64_t t0 = mach_absolute_time();
    uint64_t limit_ns = (uint64_t)(seconds * 1e9);
    while (1) {
        uint64_t ns = (mach_absolute_time() - t0) * tbi.numer / tbi.denom;
        if (ns > limit_ns) break;
        measure_gflops();
    }
}

// ─── Powermetrics confirmation ──────────────────────────────────────────────

static void confirm_frequency(void) {
    if (!g_confirm) return;
    printf("\n");
    LOG_INFO("Confirming GPU frequency via powermetrics (3 samples)...");
    fflush(stdout);
    FILE *pp = popen("powermetrics --samplers gpu_power -i 300 -n 3 2>/dev/null", "r");
    if (!pp) { LOG_WARN("Could not run powermetrics (need sudo)"); return; }
    char line[4096];
    while (fgets(line, sizeof(line), pp)) {
        if (strstr(line, "GPU HW active frequency:")) {
            char *colon = strchr(line, ':');
            if (colon) printf("  %sFrequency:%s%s", g_color ? C_BOLD : "", g_color ? C_RESET : "", colon + 1);
        }
        if (strstr(line, "GPU Power:")) {
            char *colon = strchr(line, ':');
            if (colon) printf("  %sPower:    %s%s", g_color ? C_BOLD : "", g_color ? C_RESET : "", colon + 1);
        }
    }
    pclose(pp);
}

// ─── DVFS table ─────────────────────────────────────────────────────────────

typedef struct { uint32_t freq_mhz; uint32_t voltage_mv; uint32_t sram_mv; } PState;

// The device tree lays the table out as voltage corners (M2 Max: 4 corners x 9
// states = 36 entries). The buffer must exceed any known table, or the top
// states silently disappear and every consumer reads a truncated table.
#define DVFS_MAX_STATES 64

static int read_dvfs_table(PState *out, int max_entries) {
    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceNameMatching("sgx"), &iter);
    if (kr != KERN_SUCCESS) return 0;
    io_service_t svc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    if (!svc) return 0;
    int count = 0;
    CFTypeRef ps_ref = IORegistryEntryCreateCFProperty(svc, CFSTR("perf-states"), NULL, 0);
    CFTypeRef sram_ref = IORegistryEntryCreateCFProperty(svc, CFSTR("perf-states-sram"), NULL, 0);
    if (ps_ref && CFGetTypeID(ps_ref) == CFDataGetTypeID()) {
        CFDataRef ps_data = (CFDataRef)ps_ref;
        CFDataRef sram_data = sram_ref && CFGetTypeID(sram_ref) == CFDataGetTypeID()
                            ? (CFDataRef)sram_ref : NULL;
        CFIndex len = CFDataGetLength(ps_data);
        const uint8_t *bytes = CFDataGetBytePtr(ps_data);
        const uint8_t *sram_bytes = sram_data ? CFDataGetBytePtr(sram_data) : NULL;
        count = (int)(len / 8);
        if (count > max_entries) {
            fprintf(stderr, "  warning: device tree exposes %d P-states, buffer holds %d"
                            " — raise DVFS_MAX_STATES\n", count, max_entries);
            count = max_entries;
        }
        for (int i = 0; i < count; i++) {
            uint32_t freq, mv, smv = 0;
            memcpy(&freq, bytes + i * 8, 4);
            memcpy(&mv, bytes + i * 8 + 4, 4);
            if (sram_bytes) memcpy(&smv, sram_bytes + i * 8 + 4, 4);
            out[i].freq_mhz = freq / 1000000;
            out[i].voltage_mv = mv;
            out[i].sram_mv = smv;
        }
    }
    if (ps_ref) CFRelease(ps_ref);
    if (sram_ref) CFRelease(sram_ref);
    IOObjectRelease(svc);
    return count;
}

// ─── Commands ───────────────────────────────────────────────────────────────

static void cmd_info(void) {
    SoCInfo soc = detect_soc();
    printf("%sSoC Detection%s\n", g_color ? C_BOLD : "", g_color ? C_RESET : "");
    printf("  CPU:          %s\n", soc.soc_name[0] ? soc.soc_name : "(unknown)");
    printf("  GPU DT:       %s\n", soc.compatible[0] ? soc.compatible : "(unknown)");
    printf("  GPU class:    %s\n", soc.agx_class[0] ? soc.agx_class : "(unknown)");
    printf("  GPU cores:    %d\n", soc.gpu_cores);
    printf("  CLPC driver:  %s\n", soc.clpc_class);

    int64_t max_mw = agx_get_max_power();
    if (max_mw >= 0)
        printf("  GPU power:    %lld mW (MaxGPUAbsolutePower)\n", max_mw);

    PState ps[DVFS_MAX_STATES];
    int n = read_dvfs_table(ps, DVFS_MAX_STATES);
    if (n > 0) {
        printf("  P-states:     %d\n", n);
        // Min/max over operating states. The table is grouped into voltage
        // corners, so ps[n-1] is not the highest state — reading ps[1]/ps[n-1]
        // under-reported the range (444–968 MHz instead of 444–1398 on M2 Max).
        uint32_t fmin = 0, fmax = 0, vmin = 0, vmax = 0;
        int corners = 0, in_corner = 0;
        for (int i = 0; i < n; i++) {
            if (ps[i].freq_mhz == 0) { in_corner = 0; continue; }   // idle ends a corner
            if (!in_corner) { corners++; in_corner = 1; }
            if (fmin == 0 || ps[i].freq_mhz < fmin) fmin = ps[i].freq_mhz;
            if (ps[i].freq_mhz > fmax) fmax = ps[i].freq_mhz;
            if (vmin == 0 || ps[i].voltage_mv < vmin) vmin = ps[i].voltage_mv;
            if (ps[i].voltage_mv > vmax) vmax = ps[i].voltage_mv;
        }
        printf("  Freq range:   %u – %u MHz (operating states)\n", fmin, fmax);
        printf("  Voltage:      %u – %u mV over %d voltage corner%s\n",
               vmin, vmax, corners, corners == 1 ? "" : "s");
    }
}

static void cmd_status(void) {
    SoCInfo soc = detect_soc();
    printf("%s── GPU DVFS Status ──%s\n\n", g_color ? C_BOLD : "", g_color ? C_RESET : "");
    printf("  Device:  %s (%s, %d cores)\n", soc.agx_class, soc.compatible, soc.gpu_cores);

    // AGX power info
    int64_t max_mw = agx_get_max_power();
    int64_t cur_mw = agx_get_filtered_power();
    printf("\n%sGPU Power (AGX):%s\n", g_color ? C_BOLD : "", g_color ? C_RESET : "");
    printf("  MaxGPUAbsolutePower:  %s%lld mW%s (%.1f W)\n",
           g_color ? C_CYAN : "", max_mw, g_color ? C_RESET : "", max_mw / 1000.0);
    printf("  FilteredGPUPower:     %lld mW (%.1f W)\n", cur_mw, cur_mw / 1000.0);

    // CLPC info
    int64_t lpt = clpc_get("`pkg-low-power-target");
    printf("\n%sCLPC:%s\n", g_color ? C_BOLD : "", g_color ? C_RESET : "");
    printf("  pkg-avg-max-power:    %.2f W\n", clpc_get("~pkg-avg-max-power") / 1048576.0);
    printf("  pkg-low-power-target: ");
    if (lpt < 0) printf("%sdisabled%s\n", g_color ? C_GREEN : "", g_color ? C_RESET : "");
    else printf("%s%.2f W%s\n", g_color ? C_YELLOW : "", lpt / 1048576.0, g_color ? C_RESET : "");

    int saved = access(STATEFILE, F_OK) == 0;
    if (saved) printf("\n  %sSaved state available%s — run 'uncap' to restore\n",
                      g_color ? C_YELLOW : "", g_color ? C_RESET : "");

    printf("\n%sGPU Benchmark%s (2048×2048 FP32 matmul, best of 5):\n",
           g_color ? C_BOLD : "", g_color ? C_RESET : "");
    double gf = measure_gflops();
    printf("  %s%.1f GFLOPS%s", g_color ? C_BOLD : "", gf, g_color ? C_RESET : "");
    if (gf > 500) printf("  %s← peak%s\n", g_color ? C_GREEN : "", g_color ? C_RESET : "");
    else if (gf > 200) printf("  %s← throttled%s\n", g_color ? C_YELLOW : "", g_color ? C_RESET : "");
    else printf("  %s← heavily throttled%s\n", g_color ? C_RED : "", g_color ? C_RESET : "");

    confirm_frequency();
}

static void cmd_cap(double watts) {
    int64_t mw = (int64_t)(watts * 1000.0);
    int use_agx = agx_available();

    if (use_agx) {
        // AGX path — save original, set new cap
        int64_t orig_mw = agx_get_max_power();
        AGXSavedState ss = { .magic = STATE_MAGIC_AGX, .agx_max_power = orig_mw };
        FILE *f = fopen(STATEFILE, "wb");
        if (f) { fwrite(&ss, sizeof(ss), 1, f); fclose(f); }
        LOG_OK("Saved original GPU power cap: %lld mW (%.1f W)", orig_mw, orig_mw / 1000.0);

        LOG_INFO("Setting GPU power cap to %lld mW (%.1f W) via AGX...", mw, watts);
        kern_return_t kr = agx_set_power(mw);
        if (kr != KERN_SUCCESS) {
            LOG_ERR("AGX write failed (0x%x), falling back to CLPC", kr);
            goto clpc_fallback;
        }

        burn_in_gpu(10.0);

        double gf = measure_gflops();
        int64_t actual = agx_get_filtered_power();
        LOG_OK("GPU capped: %.1f GFLOPS (power: %lld mW, cap: %lld mW)", gf, actual, mw);
        printf("\n  Restore with: %ssudo gpu_freq_ctl uncap%s\n",
               g_color ? C_BOLD : "", g_color ? C_RESET : "");
        confirm_frequency();
        return;
    }

clpc_fallback:
    LOG_WARN("AGX path unavailable, using CLPC fallback (system-wide, has PID lag)");

    CLPCState orig = clpc_read_state();
    CLPCSavedState css = { .magic = STATE_MAGIC_CLPC, .clpc = orig };
    FILE *f = fopen(STATEFILE, "wb");
    if (f) { fwrite(&css, sizeof(css), 1, f); fclose(f); }
    LOG_OK("Saved CLPC state");

    int64_t raw = (int64_t)(watts * 1048576.0);
    LOG_INFO("Setting CLPC power cap to %.1f W...", watts);
    clpc_set("~pkg-avg-max-power", raw);
    clpc_set("~pkg-lowpeak-max-power", raw);
    clpc_set("`pkg-low-power-target", raw);
    if (watts < 5.0) clpc_set("~pkg-power-zone-target-0", raw * 2);

    burn_in_gpu(10.0);

    double gf = measure_gflops();
    LOG_OK("GPU throttled: %.1f GFLOPS (CLPC cap %.1f W)", gf, watts);
    printf("\n  Restore with: %ssudo gpu_freq_ctl uncap%s\n",
           g_color ? C_BOLD : "", g_color ? C_RESET : "");
    confirm_frequency();
}

static void cmd_uncap(void) {
    FILE *f = fopen(STATEFILE, "rb");
    if (!f) {
        // No saved state — try AGX restore to a safe default
        LOG_WARN("No saved state found");
        if (agx_available()) {
            LOG_INFO("Restoring AGX MaxGPUAbsolutePower to 20000 mW (default)...");
            agx_set_power(20000);
        }
        goto measure;
    }

    uint32_t magic;
    fread(&magic, 4, 1, f);
    fseek(f, 0, SEEK_SET);

    if (magic == STATE_MAGIC_AGX) {
        AGXSavedState ss;
        fread(&ss, sizeof(ss), 1, f);
        fclose(f);
        LOG_INFO("Restoring AGX power cap to %lld mW (%.1f W)...",
                 ss.agx_max_power, ss.agx_max_power / 1000.0);
        agx_set_power(ss.agx_max_power);
        unlink(STATEFILE);
        LOG_OK("AGX power cap restored");
    } else if (magic == STATE_MAGIC_CLPC) {
        CLPCSavedState css;
        fread(&css, sizeof(css), 1, f);
        fclose(f);
        LOG_INFO("Restoring CLPC state (fallback path)...");
        clpc_write_state(&css.clpc);
        unlink(STATEFILE);
        LOG_OK("CLPC properties restored");
        LOG_INFO("Waiting 5s for CLPC to settle...");
        sleep(5);
    } else {
        fclose(f);
        LOG_ERR("Corrupt state file — removing");
        unlink(STATEFILE);
        if (agx_available()) agx_set_power(20000);
    }

measure:;
    double gf = measure_gflops();
    if (gf > 500) LOG_OK("GPU recovered: %.1f GFLOPS", gf);
    else {
        LOG_WARN("GPU at %.1f GFLOPS — may need more time", gf);
        if (!agx_available())
            printf("  If stuck: %ssudo pmset sleepnow%s (resets CLPC)\n",
                   g_color ? C_BOLD : "", g_color ? C_RESET : "");
    }
    confirm_frequency();
}

static void cmd_sweep(void) {
    int use_agx = agx_available();
    int64_t orig_mw = use_agx ? agx_get_max_power() : 0;
    CLPCState orig_clpc;
    if (!use_agx) orig_clpc = clpc_read_state();

    LOG_INFO("Starting power cap sweep (%s path)...", use_agx ? "AGX" : "CLPC");

    double caps_w[] = {1.0, 2.0, 3.0, 5.0, 8.0, 10.0, 15.0, 20.0};
    int n_caps = sizeof(caps_w) / sizeof(caps_w[0]);

    printf("\n  %sCap (W)  Cap (mW)   GFLOPS   Power mW   Ratio%s\n",
           g_color ? C_BOLD : "", g_color ? C_RESET : "");
    printf("  ──────   ────────   ──────   ────────   ─────\n");

    double peak_gf = 0;

    for (int i = n_caps - 1; i >= 0; i--) {
        int64_t mw = (int64_t)(caps_w[i] * 1000);
        if (use_agx) {
            agx_set_power(mw);
            // Same methodology as `cap`. The old sleep(2) left the low caps
            // (<= 2 W) unconverged, which is the opposite of what a sweep is for.
            burn_in_gpu(10.0);
        } else {
            clpc_write_state(&orig_clpc);
            int64_t raw = (int64_t)(caps_w[i] * 1048576.0);
            clpc_set("~pkg-avg-max-power", raw);
            clpc_set("~pkg-lowpeak-max-power", raw);
            clpc_set("`pkg-low-power-target", raw);
            if (caps_w[i] < 5.0) clpc_set("~pkg-power-zone-target-0", raw * 2);
            burn_in_gpu(10.0);   // CLPC's PID needs the sustained load even more
        }

        double gf = measure_gflops();
        int64_t actual = use_agx ? agx_get_filtered_power() : -1;
        if (gf > peak_gf) peak_gf = gf;
        printf("  %5.1f    %7lld    %6.1f   %8lld   %5.1f%%\n",
               caps_w[i], mw, gf, actual, peak_gf > 0 ? gf / peak_gf * 100 : 100.0);
        fflush(stdout);
    }

    printf("\n");
    LOG_INFO("Restoring...");
    if (use_agx) {
        agx_set_power(orig_mw);
        sleep(1);
    } else {
        clpc_write_state(&orig_clpc);
        sleep(5);
    }
    double gf = measure_gflops();
    LOG_OK("Restored: %.1f GFLOPS", gf);
}

static void cmd_table(void) {
    SoCInfo soc = detect_soc();
    PState ps[DVFS_MAX_STATES];
    int count = read_dvfs_table(ps, DVFS_MAX_STATES);
    if (count == 0) { LOG_ERR("Could not read DVFS table from device tree"); return; }

    printf("%s── GPU DVFS Table (%s, %d P-states) ──%s\n\n",
           g_color ? C_BOLD : "", soc.compatible[0] ? soc.compatible : "?",
           count, g_color ? C_RESET : "");
    printf("  P-state   Freq MHz   GPU mV   SRAM mV   Notes\n");
    printf("  ───────   ────────   ──────   ───────   ─────\n");

    // Read base P-state once
    int base_ps = 3;
    {
        io_iterator_t it2;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("sgx"), &it2) == KERN_SUCCESS) {
            io_service_t sv2 = IOIteratorNext(it2);
            if (sv2) {
                CFTypeRef ref = IORegistryEntryCreateCFProperty(sv2, CFSTR("gpu-perf-base-pstate"), NULL, 0);
                if (ref && CFGetTypeID(ref) == CFDataGetTypeID()) {
                    uint32_t bval = 0;
                    CFDataGetBytes((CFDataRef)ref, CFRangeMake(0, 4), (UInt8 *)&bval);
                    base_ps = bval;
                }
                if (ref) CFRelease(ref);
                IOObjectRelease(sv2);
            }
            IOObjectRelease(it2);
        }
    }

    uint32_t prev_v = 0;
    for (int i = 0; i < count; i++) {
        const char *note = "";
        char note_buf[64] = {0};
        if (i == 0) note = "idle/retention";
        else if (ps[i].voltage_mv == prev_v && prev_v > 0) {
            snprintf(note_buf, sizeof(note_buf), "+%d MHz (same V)",
                     (int)ps[i].freq_mhz - (int)ps[i-1].freq_mhz);
            note = note_buf;
        }
        if (i == base_ps && note[0] == 0) note = "← base";
        if (i == count - 1 && note[0] == 0) note = "← peak";

        printf("  %sP%-2d%s       %5u      %5u    %5u     %s%s%s\n",
               (i == 0) ? (g_color ? C_DIM : "") :
               (i == count - 1) ? (g_color ? C_RED : "") :
               (i == base_ps) ? (g_color ? C_GREEN : "") : "",
               i, g_color ? C_RESET : "",
               ps[i].freq_mhz, ps[i].voltage_mv, ps[i].sram_mv,
               g_color ? C_DIM : "", note, g_color ? C_RESET : "");
        prev_v = ps[i].voltage_mv;
    }

    int corner_pairs = 0;
    for (int i = 1; i < count - 1; i++)
        if (i + 1 < count && ps[i].voltage_mv == ps[i+1].voltage_mv && ps[i].voltage_mv > 0) corner_pairs++;
    if (corner_pairs > 0) {
        printf("\n  %sVoltage corners:%s\n", g_color ? C_BOLD : "", g_color ? C_RESET : "");
        for (int i = 1; i < count - 1; i++) {
            if (i + 1 < count && ps[i].voltage_mv == ps[i+1].voltage_mv && ps[i].voltage_mv > 0)
                printf("    %4u mV: %u ↔ %u MHz (Δ%d)\n",
                       ps[i].voltage_mv, ps[i].freq_mhz, ps[i+1].freq_mhz,
                       (int)ps[i+1].freq_mhz - (int)ps[i].freq_mhz);
        }
    } else {
        // M2 Max and relatives ramp GPU mV at every step; an empty list under a
        // printed header reads as a bug, so say what is actually going on.
        printf("\n  %sVoltage corners:%s none at equal GPU mV on this chip"
               " — corner boundaries are visible in the SRAM column\n",
               g_color ? C_BOLD : "", g_color ? C_RESET : "");
    }

    uint32_t sram_floor = 0;
    for (int i = 0; i < count; i++)
        if (ps[i].sram_mv > 0 && (sram_floor == 0 || ps[i].sram_mv < sram_floor))
            sram_floor = ps[i].sram_mv;
    if (sram_floor > 0) {
        int floor_end = 0;
        for (int i = 0; i < count; i++)
            if (ps[i].sram_mv == sram_floor) floor_end = i;
        printf("\n  %sSRAM floor:%s %u mV (P0–P%d); GPU logic runs lower\n",
               g_color ? C_BOLD : "", g_color ? C_RESET : "", sram_floor, floor_end);
    }
}

// ─── Main ───────────────────────────────────────────────────────────────────

static void print_usage(void) {
    printf("%sgpu_freq_ctl%s — Apple Silicon GPU frequency control\n\n",
           g_color ? C_BOLD : "", g_color ? C_RESET : "");
    printf("Primary: AGX SetMaxGPUAbsolutePower (GPU-only, instant, M1–M5)\n");
    printf("Fallback: CLPC pkg-low-power-target (system-wide, has PID lag)\n\n");
    printf("Usage:\n");
    printf("  sudo gpu_freq_ctl %sstatus%s           Current state + GPU speed\n",
           g_color ? C_CYAN : "", g_color ? C_RESET : "");
    printf("  sudo gpu_freq_ctl %scap%s <watts>      Cap GPU power (e.g. 5 = 5W)\n",
           g_color ? C_CYAN : "", g_color ? C_RESET : "");
    printf("  sudo gpu_freq_ctl %suncap%s            Restore GPU power cap\n",
           g_color ? C_CYAN : "", g_color ? C_RESET : "");
    printf("  sudo gpu_freq_ctl %ssweep%s            Sweep power levels + measure\n",
           g_color ? C_CYAN : "", g_color ? C_RESET : "");
    printf("       gpu_freq_ctl %stable%s            Print DVFS P-state table\n",
           g_color ? C_CYAN : "", g_color ? C_RESET : "");
    printf("       gpu_freq_ctl %sinfo%s             Show detected SoC + GPU\n",
           g_color ? C_CYAN : "", g_color ? C_RESET : "");
    printf("\nFlags:\n");
    printf("  -v, --verbose     Show IOKit calls and raw values\n");
    printf("  --confirm         Run powermetrics after cap/uncap to verify\n");
    printf("  --no-burn         Skip burn-in during cap (faster)\n");
    printf("  --clpc            Force CLPC fallback path\n");
    printf("  --no-color        Disable colored output\n");
}

int main(int argc, char **argv) {
    if (!isatty(STDOUT_FILENO)) g_color = 0;

    int cmd_idx = -1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "--verbose") == 0) g_verbose = 1;
        else if (strcmp(argv[i], "--confirm") == 0) g_confirm = 1;
        else if (strcmp(argv[i], "--no-burn") == 0) g_no_burn = 1;
        else if (strcmp(argv[i], "--clpc") == 0) g_force_clpc = 1;
        else if (strcmp(argv[i], "--no-color") == 0) g_color = 0;
        else if (cmd_idx < 0) cmd_idx = i;
    }

    if (cmd_idx < 0) { print_usage(); return 0; }
    const char *cmd = argv[cmd_idx];

    if (strcmp(cmd, "table") == 0) { cmd_table(); return 0; }
    if (strcmp(cmd, "info") == 0) { cmd_info(); return 0; }

    if (geteuid() != 0) { LOG_ERR("Need root — run with sudo"); return 1; }

    if (strcmp(cmd, "status") == 0) cmd_status();
    else if (strcmp(cmd, "cap") == 0) {
        if (cmd_idx + 1 >= argc) { LOG_ERR("Usage: gpu_freq_ctl cap <watts>"); return 1; }
        double watts = atof(argv[cmd_idx + 1]);
        if (watts <= 0 || watts > 200) { LOG_ERR("Power cap must be 0.1–200 W"); return 1; }
        cmd_cap(watts);
    }
    else if (strcmp(cmd, "uncap") == 0) cmd_uncap();
    else if (strcmp(cmd, "sweep") == 0) cmd_sweep();
    else { LOG_ERR("Unknown command: %s", cmd); print_usage(); return 1; }

    return 0;
}
