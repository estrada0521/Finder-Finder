fn main() {
    println!("cargo:rerun-if-changed=src/quicklook_panel.m");
    println!("cargo:rerun-if-changed=src/native_shell.m");
    cc::Build::new()
        .file("src/quicklook_panel.m")
        .file("src/native_shell.m")
        .flag("-fobjc-arc")
        .compile("finder_quicklook_panel");
    // Objective-C class references are resolved dynamically, so force dyld to
    // load this framework instead of allowing the linker to dead-strip it.
    println!("cargo:rustc-link-arg=-Wl,-needed_framework,QuickLookUI");
    println!("cargo:rustc-link-lib=framework=QuickLookThumbnailing");
    println!("cargo:rustc-link-lib=framework=Cocoa");
}
