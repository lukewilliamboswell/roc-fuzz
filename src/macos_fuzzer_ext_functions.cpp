// libFuzzer's Darwin implementation normally finds application hooks with
// dlsym, which needs a linker export-dynamic flag Roc does not provide. Keep
// the upstream interceptor support and bind the standalone runner hooks
// directly instead.
#include "FuzzerExtFunctions.h"

extern "C" {
int LLVMFuzzerInitialize(int *argc, char ***argv);
int __sanitizer_acquire_crash_state();
void __sanitizer_print_stack_trace();
void __sanitizer_set_death_callback(void (*callback)());
}

namespace fuzzer {

ExternalFunctions::ExternalFunctions() {
  LLVMFuzzerInitialize = ::LLVMFuzzerInitialize;
  __sanitizer_acquire_crash_state = ::__sanitizer_acquire_crash_state;
  __sanitizer_print_stack_trace = ::__sanitizer_print_stack_trace;
  __sanitizer_set_death_callback = ::__sanitizer_set_death_callback;
}

}  // namespace fuzzer
