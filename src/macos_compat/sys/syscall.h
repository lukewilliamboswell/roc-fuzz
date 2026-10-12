// Deliberately empty. libFuzzer's FuzzerUtilPosix.cpp includes <sys/syscall.h>
// and uses nothing from it on Darwin. Zig's bundled macOS headers do not carry
// the file, and the build reads no installed Apple SDK, so this stands in.
