// Roc's macOS stack-depth instrumentation requires an externally visible TLS
// slot. The libFuzzer source defines an internal Darwin TLS slot, so provide
// the linker-visible definition from the host archive.
#include <stdint.h>

__thread uintptr_t __sancov_lowest_stack;
