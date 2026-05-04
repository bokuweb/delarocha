#![no_main]

use delarocha::Dictionary;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(input) = std::str::from_utf8(data) else {
        return;
    };
    if input.len() > 8192 {
        return;
    }

    let _ = Dictionary::parse(input);
});
