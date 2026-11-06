/* omso DAW's build configuration for LAME 3.100 (third_party/lame, unmodified), written for macOS with Clang
   (arm64 and x86_64) in place of the configure script's config.h; see cmake/Lame.cmake. Only the encoder library is
   built: no decoder (HAVE_MPGLIB), no assembly (HAVE_NASM), no front end. */
#ifndef LAME_CONFIG_H
#define LAME_CONFIG_H

#define STDC_HEADERS 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_LIMITS_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HAVE_MEMORY_H 1
#define HAVE_DLFCN_H 1
#define HAVE_STRCHR 1
#define HAVE_MEMCPY 1

/* The fixed-width types come from <inttypes.h>. */
#define HAVE_INT8_T 1
#define HAVE_INT16_T 1
#define HAVE_INT32_T 1
#define HAVE_INT64_T 1
#define HAVE_UINT8_T 1
#define HAVE_UINT16_T 1
#define HAVE_UINT32_T 1
#define HAVE_UINT64_T 1
typedef float ieee754_float32_t;
typedef double ieee754_float64_t;
typedef long double ieee854_float80_t;

#define SIZEOF_DOUBLE 8
#define SIZEOF_FLOAT 4
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_LONG_LONG 8
#define SIZEOF_SHORT 2
#define SIZEOF_UNSIGNED_INT 4
#define SIZEOF_UNSIGNED_LONG 8
#define SIZEOF_UNSIGNED_LONG_LONG 8
#define SIZEOF_UNSIGNED_SHORT 2

/* As the configure script chooses for these compilers. */
#define USE_FAST_LOG 1
#define LAME_LIBRARY_BUILD 1

/* x86_64 only: the IEEE 754 shortcuts and SSE quantization (vector/xmm_quantize_sub.c); elsewhere the portable C. */
#if defined(__x86_64__)
#define TAKEHIRO_IEEE754_HACK 1
#define HAVE_XMMINTRIN_H 1
#endif

#define PACKAGE "lame"
#define PACKAGE_NAME "lame"
#define PACKAGE_VERSION "3.100"
#define VERSION "3.100"

#endif
