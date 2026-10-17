use std::{env, fs, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=OMPUTER_EMBED_RESOURCES");
    let output = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo OUT_DIR"));
    let destination = output.join("resources.tar.zst");
    match env::var_os("OMPUTER_EMBED_RESOURCES") {
        Some(source) => {
            let source = PathBuf::from(source)
                .canonicalize()
                .expect("Embedded resource archive exists");
            println!("cargo:rerun-if-changed={}", source.display());
            fs::copy(source, destination).expect("Copy embedded resource archive");
        }
        None => fs::write(destination, []).expect("Create empty development resource archive"),
    }
}
