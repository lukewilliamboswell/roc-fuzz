#include <cstddef>
#include <cstdint>
#include <vector>

// Exercise libFuzzer's input lifecycle with ordinary heap activity. The
// sanitizer job builds this callback and the pinned runtime from source.
extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t *data,
                                      std::size_t size) {
  std::vector<std::uint8_t> copy(data, data + size);
  volatile std::uint8_t first = copy.empty() ? 0 : copy.front();
  (void)first;
  return 0;
}
