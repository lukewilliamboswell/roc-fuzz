mod roc_platform_abi;

use core::ffi::c_void;
use core::ptr;
use roc_platform_abi::{make_roc_host, roc_fuzz, DefaultAllocators, DefaultHandlers, RocListWith};

/// Pass one libFuzzer input across the generated Roc platform ABI.
pub fn call_roc(data: &[u8]) -> u8 {
    let host = make_roc_host(ptr::null_mut());
    let input = unsafe { RocListWith::<u8, false>::from_slice(data, &host) };

    // The natural ABI transfers ownership of the list to Roc.
    unsafe { roc_fuzz(input) }
}

#[no_mangle]
pub extern "C" fn roc_alloc(length: usize, alignment: usize) -> *mut c_void {
    DefaultAllocators::roc_alloc(ptr::null_mut(), length, alignment)
}

#[no_mangle]
pub extern "C" fn roc_dealloc(pointer: *mut c_void, alignment: usize) {
    DefaultAllocators::roc_dealloc(ptr::null_mut(), pointer, alignment)
}

#[no_mangle]
pub extern "C" fn roc_realloc(
    pointer: *mut c_void,
    new_length: usize,
    alignment: usize,
) -> *mut c_void {
    DefaultAllocators::roc_realloc(ptr::null_mut(), pointer, new_length, alignment)
}

#[no_mangle]
pub extern "C" fn roc_dbg(bytes: *const u8, len: usize) {
    DefaultHandlers::roc_dbg(ptr::null_mut(), bytes, len)
}

#[no_mangle]
pub extern "C" fn roc_expect_failed(bytes: *const u8, len: usize) {
    abort_with_roc_message("EXPECT FAILED", bytes, len)
}

#[no_mangle]
pub extern "C" fn roc_crashed(bytes: *const u8, len: usize) {
    abort_with_roc_message("CRASHED", bytes, len)
}

fn abort_with_roc_message(kind: &str, bytes: *const u8, len: usize) -> ! {
    let message = if len == 0 {
        &[]
    } else {
        assert!(
            !bytes.is_null(),
            "Roc passed a null pointer for a nonempty message"
        );
        unsafe { core::slice::from_raw_parts(bytes, len) }
    };
    eprintln!("[ROC {kind}] {}", String::from_utf8_lossy(message));
    std::process::abort()
}

#[cfg(test)]
mod tests {
    #[test]
    fn calls_generated_roc_entrypoint() {
        assert_eq!(super::call_roc(b"Roc quality smoke test"), 0);
    }
}
