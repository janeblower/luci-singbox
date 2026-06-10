#![no_std]
#![no_main]

use core::arch::{asm, global_asm};

#[inline]
unsafe fn syscall6(n: usize, a1: usize, a2: usize, a3: usize,
                   a4: usize, a5: usize, a6: usize) -> isize {
    let ret: isize;
    asm!(
        "syscall",
        inlateout("rax") n => ret,
        in("rdi") a1, in("rsi") a2, in("rdx") a3,
        in("r10") a4, in("r8") a5, in("r9") a6,
        out("rcx") _, out("r11") _,
        options(nostack, preserves_flags),
    );
    ret
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    unsafe { syscall6(231, 134, 0, 0, 0, 0, 0); }
    loop {}
}

global_asm!(
    ".global _start",
    "_start:",
    "xor rbp, rbp",
    "mov rdi, rsp",
    "and rsp, -16",
    "call rust_entry",
);

#[no_mangle]
unsafe extern "C" fn rust_entry(_sp: *const usize) -> ! {
    let msg = b"ok\n";
    syscall6(1, 1, msg.as_ptr() as usize, msg.len(), 0, 0, 0); // write(1, "ok\n")
    syscall6(231, 0, 0, 0, 0, 0, 0);                            // exit_group(0)
    loop {}
}
