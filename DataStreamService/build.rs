use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let out_dir = PathBuf::from(env::var("OUT_DIR")?);

    let proto_path = "proto/duplex_stream.proto";
    println!("cargo:rerun-if-changed={}", proto_path);

    // 1. Prost
    let mut config = prost_build::Config::new();
    config.out_dir(&out_dir);
    config.compile_protos(&[proto_path], &["proto/"])?;

    // 2. protoc-gen-actrframework
    let plugin = find_plugin()?;
    let actrframework_out = out_dir.join("actrframework");
    std::fs::create_dir_all(&actrframework_out)?;

    let status = Command::new("protoc")
        .arg("--proto_path=proto")
        .arg(format!(
            "--actrframework_out={}",
            actrframework_out.display()
        ))
        .arg(format!(
            "--plugin=protoc-gen-actrframework={}",
            plugin.display()
        ))
        .arg(proto_path)
        .status()?;

    if !status.success() {
        panic!("protoc-gen-actrframework failed");
    }

    // Copy the generated .rs file
    copy_rs_recursive(&actrframework_out, &out_dir, "duplex_stream_actor.rs")?;

    Ok(())
}

fn find_plugin() -> Result<PathBuf, Box<dyn std::error::Error>> {
    let candidates = [
        // Local workspace build
        PathBuf::from("../../actr/tools/protoc-gen/rust/target/release/protoc-gen-actrframework"),
        // Homebrew / system
        PathBuf::from("/opt/homebrew/bin/protoc-gen-actrframework"),
        // Cargo bin
        {
            let home = env::var("HOME").unwrap_or_default();
            PathBuf::from(home).join(".cargo/bin/protoc-gen-actrframework")
        },
    ];

    for p in &candidates {
        if p.exists() {
            return Ok(p.clone());
        }
    }

    Err("protoc-gen-actrframework not found in any known location".into())
}

fn copy_rs_recursive(
    dir: &PathBuf,
    out_dir: &PathBuf,
    dest_name: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            copy_rs_recursive(&path, out_dir, dest_name)?;
        } else if path.extension().map_or(false, |e| e == "rs") {
            let dest = out_dir.join(dest_name);
            std::fs::copy(&path, &dest)?;
            println!("cargo:rerun-if-changed={}", path.display());
            return Ok(());
        }
    }
    Ok(())
}
