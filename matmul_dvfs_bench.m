// M4 GPU DVFS Matmul Benchmark
// Measures matmul GFLOPS across matrix sizes to show DVFS scaling.
// Small matrices → low utilization → low P-state → lower GFLOPS.
// Large matrices → sustained compute → P15 → peak GFLOPS.
//
// Build: xcrun clang -framework Metal -framework Foundation -O2 -o matmul_dvfs_bench matmul_dvfs_bench.m
// Run:   ./matmul_dvfs_bench              (just matmul timing)
//        sudo ./matmul_dvfs_bench         (with powermetrics)

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <mach/mach_time.h>

static NSString *matmulShader = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"// Tiled matmul: C[M,N] = A[M,K] * B[K,N]\n"
"// Each threadgroup computes a TILE×TILE block of C.\n"
"constant uint TILE = 16;\n"
"\n"
"kernel void matmul(\n"
"    device const float *A [[buffer(0)]],\n"
"    device const float *B [[buffer(1)]],\n"
"    device float *C       [[buffer(2)]],\n"
"    constant uint &M      [[buffer(3)]],\n"
"    constant uint &N      [[buffer(4)]],\n"
"    constant uint &K      [[buffer(5)]],\n"
"    uint2 gid [[thread_position_in_grid]],\n"
"    uint2 lid [[thread_position_in_threadgroup]])\n"
"{\n"
"    uint row = gid.y;\n"
"    uint col = gid.x;\n"
"    /* bounds handled by zero-padded loads + a guarded store */\n"
"    threadgroup float As[TILE][TILE];\n"
"    threadgroup float Bs[TILE][TILE];\n"
"\n"
"    float acc = 0.0f;\n"
"    uint numTiles = (K + TILE - 1) / TILE;\n"
"\n"
"    for (uint t = 0; t < numTiles; t++) {\n"
"        uint aCol = t * TILE + lid.x;\n"
"        uint bRow = t * TILE + lid.y;\n"
"        As[lid.y][lid.x] = (row < M && aCol < K) ? A[row * K + aCol] : 0.0f;\n"
"        Bs[lid.y][lid.x] = (bRow < K && col < N) ? B[bRow * N + col] : 0.0f;\n"
"        threadgroup_barrier(mem_flags::mem_threadgroup);\n"
"\n"
"        for (uint i = 0; i < TILE; i++) {\n"
"            acc = fma(As[lid.y][i], Bs[i][lid.x], acc);\n"
"        }\n"
"        threadgroup_barrier(mem_flags::mem_threadgroup);\n"
"    }\n"
"\n"
"    if (row < M && col < N) C[row * N + col] = acc;\n"
"}\n";

static double mach_to_ms(uint64_t elapsed) {
    static mach_timebase_info_data_t info = {0};
    if (info.denom == 0) mach_timebase_info(&info);
    return (double)elapsed * info.numer / info.denom / 1e6;
}

typedef struct {
    uint32_t M, N, K;
    double best_ms;
    double gflops;
    int warmup_runs;
    int timed_runs;
} BenchResult;

int main(int argc, char **argv) {
    int with_power = (geteuid() == 0);
    int csv_mode = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--csv") == 0) csv_mode = 1;
    }

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { fprintf(stderr, "No Metal device\n"); return 1; }

    if (!csv_mode) {
        printf("Device: %s\n\n", [[dev name] UTF8String]);
    }

    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:matmulShader options:nil error:&err];
    if (!lib) { fprintf(stderr, "Shader: %s\n", [[err description] UTF8String]); return 1; }
    id<MTLFunction> func = [lib newFunctionWithName:@"matmul"];
    id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:func error:&err];
    if (!pso) { fprintf(stderr, "PSO: %s\n", [[err description] UTF8String]); return 1; }
    id<MTLCommandQueue> queue = [dev newCommandQueue];

    // Sweep matrix sizes: small → large to show DVFS ramp
    uint32_t sizes[] = {
        16, 32, 48, 64, 96, 128, 192, 256, 384, 512,
        640, 768, 1024, 1280, 1536, 2048, 2560, 3072, 4096
    };
    int n_sizes = sizeof(sizes) / sizeof(sizes[0]);

    // Start powermetrics if root
    pid_t pm_pid = 0;
    char pm_out[256] = {0};
    if (with_power) {
        snprintf(pm_out, sizeof(pm_out), "/tmp/matmul_dvfs_pm_%d.log", getpid());
        pm_pid = fork();
        if (pm_pid == 0) {
            freopen(pm_out, "w", stdout);
            freopen("/dev/null", "w", stderr);
            execlp("powermetrics", "powermetrics",
                   "--samplers", "gpu_power", "-i", "100", "-n", "2000", NULL);
            _exit(1);
        }
        if (!csv_mode) printf("powermetrics → %s\n\n", pm_out);
        usleep(500000);
    }

    BenchResult results[32];
    int n_results = 0;

    if (!csv_mode) {
        printf("%-6s  %10s  %10s  %10s  %s\n", "Size", "Best ms", "GFLOPS", "GFLOPS/W", "Notes");
        printf("------  ----------  ----------  ----------  -----\n");
    } else {
        printf("M,N,K,best_ms,gflops\n");
    }

    for (int s = 0; s < n_sizes; s++) {
        uint32_t dim = sizes[s];
        uint32_t M = dim, N = dim, K = dim;
        size_t szA = M * K * sizeof(float);
        size_t szB = K * N * sizeof(float);
        size_t szC = M * N * sizeof(float);

        id<MTLBuffer> bufA = [dev newBufferWithLength:szA options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufB = [dev newBufferWithLength:szB options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufC = [dev newBufferWithLength:szC options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufM = [dev newBufferWithBytes:&M length:4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufN = [dev newBufferWithBytes:&N length:4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufK = [dev newBufferWithBytes:&K length:4 options:MTLResourceStorageModeShared];

        // Init A, B with small values
        float *pA = (float *)[bufA contents];
        float *pB = (float *)[bufB contents];
        for (uint32_t i = 0; i < M * K; i++) pA[i] = (float)(i % 17) * 0.01f;
        for (uint32_t i = 0; i < K * N; i++) pB[i] = (float)(i % 13) * 0.01f;

        // Adaptive run count: more runs for small matrices (fast), fewer for large
        int warmup = dim <= 256 ? 10 : (dim <= 1024 ? 5 : 2);
        int timed = dim <= 256 ? 20 : (dim <= 1024 ? 10 : 5);

        MTLSize grid = MTLSizeMake((N + 15) / 16, (M + 15) / 16, 1);  // threadgroup grid: every group is full
        MTLSize tg = MTLSizeMake(16, 16, 1);

        // Warmup
        for (int r = 0; r < warmup; r++) {
            @autoreleasepool {
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:pso];
                [enc setBuffer:bufA offset:0 atIndex:0];
                [enc setBuffer:bufB offset:0 atIndex:1];
                [enc setBuffer:bufC offset:0 atIndex:2];
                [enc setBuffer:bufM offset:0 atIndex:3];
                [enc setBuffer:bufN offset:0 atIndex:4];
                [enc setBuffer:bufK offset:0 atIndex:5];
                [enc dispatchThreadgroups:grid threadsPerThreadgroup:tg];
                [enc endEncoding];
                [cmd commit];
                [cmd waitUntilCompleted];
            }
        }

        // Timed runs — best-of-N
        double best_ms = 1e9;
        for (int r = 0; r < timed; r++) {
            @autoreleasepool {
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:pso];
                [enc setBuffer:bufA offset:0 atIndex:0];
                [enc setBuffer:bufB offset:0 atIndex:1];
                [enc setBuffer:bufC offset:0 atIndex:2];
                [enc setBuffer:bufM offset:0 atIndex:3];
                [enc setBuffer:bufN offset:0 atIndex:4];
                [enc setBuffer:bufK offset:0 atIndex:5];
                [enc dispatchThreadgroups:grid threadsPerThreadgroup:tg];
                [enc endEncoding];
                [cmd commit];
                [cmd waitUntilCompleted];

                double gpu_ms = ([cmd GPUEndTime] - [cmd GPUStartTime]) * 1000.0;
                if (gpu_ms < best_ms) best_ms = gpu_ms;
            }
        }

        double flops = 2.0 * M * N * K;
        double gflops = flops / (best_ms * 1e6);

        if (csv_mode) {
            printf("%u,%u,%u,%.4f,%.2f\n", M, N, K, best_ms, gflops);
        } else {
            const char *notes = "";
            if (dim <= 64) notes = "DVFS ~P3";
            else if (dim <= 256) notes = "DVFS ramping";
            else if (dim >= 2048) notes = "DVFS locked P15";
            printf("%-6u  %10.4f  %10.2f  %10s  %s\n", dim, best_ms, gflops, "", notes);
        }

        results[n_results++] = (BenchResult){M, N, K, best_ms, gflops, warmup, timed};
        fflush(stdout);
    }

    // Correctness: ones-matrices at a whole-tile size and a tile-boundary size.
    // C is zeroed first so an unwritten cell fails loudly instead of depending on
    // whatever the fresh buffer happened to contain.
    {
        const uint32_t csizes[] = {64, 100};
        for (int ci = 0; ci < 2; ci++) {
        uint32_t dim = csizes[ci];
        uint32_t M = dim, N = dim, K = dim;
        id<MTLBuffer> bufA = [dev newBufferWithLength:M*K*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufB = [dev newBufferWithLength:K*N*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufC = [dev newBufferWithLength:M*N*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufM = [dev newBufferWithBytes:&M length:4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufN = [dev newBufferWithBytes:&N length:4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufK = [dev newBufferWithBytes:&K length:4 options:MTLResourceStorageModeShared];

        float *pA = (float *)[bufA contents];
        float *pB = (float *)[bufB contents];
        for (uint32_t i = 0; i < M*K; i++) pA[i] = 1.0f;
        for (uint32_t i = 0; i < K*N; i++) pB[i] = 1.0f;
        memset([bufC contents], 0, M*N*4);

        @autoreleasepool {
            id<MTLCommandBuffer> cmd = [queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:pso];
            [enc setBuffer:bufA offset:0 atIndex:0];
            [enc setBuffer:bufB offset:0 atIndex:1];
            [enc setBuffer:bufC offset:0 atIndex:2];
            [enc setBuffer:bufM offset:0 atIndex:3];
            [enc setBuffer:bufN offset:0 atIndex:4];
            [enc setBuffer:bufK offset:0 atIndex:5];
            [enc dispatchThreadgroups:MTLSizeMake((N+15)/16,(M+15)/16,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
            [enc endEncoding];
            [cmd commit];
            [cmd waitUntilCompleted];
        }

        float *pC = (float *)[bufC contents];
        float expected = (float)K;
        int bad = 0; uint32_t bad_i = 0, computed = 0; float bad_v = 0.0f;
        for (uint32_t i = 0; i < M*N; i++) {
            if (pC[i] != 0.0f) computed++;
            if (fabsf(pC[i] - expected) > 0.01f && !bad) { bad = 1; bad_i = i; bad_v = pC[i]; }
        }
        if (!csv_mode) {
            printf("\nCorrectness (%u×%u, ones): %s — %u/%u cells computed\n",
                   M, N, bad ? "FAIL" : "PASS", computed, M*N);
            if (bad)
                printf("  first mismatch: C[%u] = %.3f (expected %.1f)\n", bad_i, bad_v, expected);
        }
        }
    }

    // Stop powermetrics
    if (pm_pid > 0) {
        kill(pm_pid, SIGTERM);
        waitpid(pm_pid, NULL, 0);
        if (!csv_mode) printf("Power log: %s\n", pm_out);
    }

    // Print summary
    if (!csv_mode && n_results > 0) {
        double peak = 0;
        for (int i = 0; i < n_results; i++) {
            if (results[i].gflops > peak) peak = results[i].gflops;
        }
        printf("\nPeak: %.1f GFLOPS @ %ux%u\n", peak,
               results[n_results-1].M, results[n_results-1].N);

        // M4 theoretical peak: 10 cores × 2 (FMA) × 32 (SIMD) × 1578 MHz = ~1010 GFLOPS
        // Tiled matmul without simdgroup_matrix won't get close, but shows DVFS clearly
        printf("Theoretical peak (10 cores × 1578 MHz): ~1010 GFLOPS (FP32 FMA)\n");
        printf("This tiled kernel won't reach that — simdgroup_matrix_multiply needed.\n");
        printf("The DVFS scaling curve is the point: compare small vs large.\n");
    }

    return 0;
}
