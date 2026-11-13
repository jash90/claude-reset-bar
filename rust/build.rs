//! Gives the Windows executable its icon.

fn main() {
    println!("cargo:rerun-if-changed=windows/icon.o");
    let windows = std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows");
    let x64 = std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("x86_64");
    if windows && x64 {
        // A COFF object holding nothing but the icon resource (assets/icon.ico). The linker
        // merges its .rsrc section into the executable, which is where Explorer looks.
        let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
        println!("cargo:rustc-link-arg-bins={dir}/windows/icon.o");
    }
}
