use lab_browser_lib as _;

extern "C" {
    fn lab_native_run();
}

fn main() {
    unsafe { lab_native_run() }
}
