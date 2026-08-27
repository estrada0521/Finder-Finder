use finder_finder_lib as _;

extern "C" {
    fn finder_native_run();
}

fn main() {
    unsafe { finder_native_run() }
}
