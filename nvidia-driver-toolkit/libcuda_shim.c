/* 
 * libcuda_shim.c - Bypass sm_120 (Blackwell) architecture block in libcuda.so
 * 
 * Usage: LD_PRELOAD=./libcuda_shim.so your_application
 * 
 * Build: gcc -shared -fPIC -o libcuda_shim.so libcuda_shim.c -ldl
 * 
 * This shim intercepts cuDeviceGetAttribute and modifies the compute capability
 * response to bypass the Blackwell sm_120 software block in libcuda.so
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

/* CUDA driver API types */
typedef int CUresult;
typedef int CUdevice;
typedef int CUdevice_attribute;

/* CUDA attribute enums */
#define CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR 75
#define CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR 76

/* Original function pointer */
typedef CUresult (*cuDeviceGetAttribute_t)(int *pi, CUdevice_attribute attrib, CUdevice dev);
static cuDeviceGetAttribute_t real_cuDeviceGetAttribute = NULL;

/* Debug flag - set CUDA_SHIM_DEBUG=1 to enable */
static int debug_enabled = -1;

static void init_debug() {
    if (debug_enabled == -1) {
        const char *env = getenv("CUDA_SHIM_DEBUG");
        debug_enabled = (env && env[0] == '1') ? 1 : 0;
    }
}

/* Intercepted cuDeviceGetAttribute */
CUresult cuDeviceGetAttribute(int *pi, CUdevice_attribute attrib, CUdevice dev) {
    init_debug();
    
    /* Lazy initialization of real function */
    if (!real_cuDeviceGetAttribute) {
        real_cuDeviceGetAttribute = (cuDeviceGetAttribute_t)dlsym(RTLD_NEXT, "cuDeviceGetAttribute");
        if (!real_cuDeviceGetAttribute) {
            if (debug_enabled) fprintf(stderr, "[CUDA_SHIM] ERROR: Could not find real cuDeviceGetAttribute\n");
            return 1; /* CUDA_ERROR_INVALID_VALUE */
        }
    }
    
    /* Call original function first */
    CUresult result = real_cuDeviceGetAttribute(pi, attrib, dev);
    
    /* If device reports sm_120 (Blackwell), report as sm_90 (Hopper) to bypass block */
    if (result == 0 && pi != NULL) {
        if (attrib == CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR && *pi == 12) {
            if (debug_enabled) fprintf(stderr, "[CUDA_SHIM] Masking compute major 12 -> 9 (sm_120 -> sm_90)\n");
            *pi = 9; /* Report as Hopper */
        }
        else if (attrib == CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR && *pi == 0) {
            /* Keep minor at 0 for both sm_120 and sm_90 */
            if (debug_enabled) fprintf(stderr, "[CUDA_SHIM] Compute minor: %d\n", *pi);
        }
    }
    
    return result;
}

/* Constructor - runs when library is loaded */
__attribute__((constructor))
static void shim_init(void) {
    init_debug();
    if (debug_enabled) {
        fprintf(stderr, "[CUDA_SHIM] Loaded - will bypass sm_120 (Blackwell) architecture check\n");
    }
}
