#![allow(unused)] // bro I said SHUT UP!

use std::env;
use std::process::Command;

fn main() {
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or("unknown".to_string());

    let (shader_backend, shader) = match target_os.as_str() {
        "windows" => ("hlsl5", "./sokol-shdc-win.exe"),
        "macos" => ("metal_macos", "./sokol-shdc-mac"),
        "linux" => ("glsl430", "./sokol-shdc-linux"),
        _ => panic!("Unsupported OS: {}", target_os),
    };

    Command::new(shader)
        .args(&[
            "-i",
            "src/shader.glsl",
            "-o",
            "src/generated_shader.rs",
            "-l",
            shader_backend,
            "-f",
            "sokol_rust",
        ])
        .status()
        .unwrap();
}
