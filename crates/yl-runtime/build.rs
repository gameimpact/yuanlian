fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        let source = "../../client/windows/runner";
        cc::Build::new()
            .cpp(true)
            .std("c++17")
            .flag("/utf-8")
            .define("NOMINMAX", None)
            .include(source)
            .file(format!("{source}/quality_process.cpp"))
            .file("process_bridge.cpp")
            .compile("yl_owned_process");
        println!("cargo:rustc-link-lib=user32");
        println!("cargo:rerun-if-changed={source}/quality_process.cpp");
        println!("cargo:rerun-if-changed={source}/quality_process.h");
        println!("cargo:rerun-if-changed=process_bridge.cpp");
    }
}
