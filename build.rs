use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    for variable in [
        "ROC",
        "ROC_ALLOW_UNPINNED",
        "ROC_FUZZ_APP",
        "ROC_FUZZ_ARCHIVE",
        "ROC_FUZZ_INSTRUMENT",
        "ROC_FUZZ_TARGET",
    ] {
        println!("cargo:rerun-if-env-changed={variable}");
    }
    for source in [
        ".roc-version",
        "platform/main.roc",
        "platform/Arbitrary.roc",
    ] {
        println!("cargo:rerun-if-changed={source}");
    }

    if let Some(archive) = prebuilt_archive() {
        link_archive(&archive);
        return;
    }
    if env::var_os("ROC_FUZZ_APP").is_none() && env::var_os("ROC_FUZZ_TARGET").is_none() {
        println!(
            "cargo:warning=roc-fuzz host built without a Roc archive; set ROC_FUZZ_ARCHIVE when linking a fuzz target"
        );
        return;
    }

    let pinned = read_pin(Path::new(".roc-version"));
    let roc = env::var_os("ROC").unwrap_or_else(|| "roc".into());
    let version = Command::new(&roc)
        .arg("version")
        .output()
        .unwrap_or_else(|error| panic!("failed to run {:?} version: {error}", roc));
    if !version.status.success() {
        panic!("{:?} version failed", roc);
    }
    let version_text = String::from_utf8_lossy(&version.stdout).trim().to_owned();
    let using_pin = compiler_matches_pin(&version_text, &pinned);
    let allow_unpinned = env::var("ROC_ALLOW_UNPINNED").as_deref() == Ok("1");
    if !using_pin && !allow_unpinned {
        panic!(
            "Roc version mismatch: .roc-version pins {pinned}, but {roc:?} reports {version_text:?}. \
             Set ROC_ALLOW_UNPINNED=1 only for intentional compiler development."
        );
    }

    let source = source_path();
    watch_roc_sources(&source);

    let instrument = match env::var("ROC_FUZZ_INSTRUMENT") {
        Ok(value) if value == "1" => true,
        Ok(value) if value == "0" => false,
        Ok(value) => panic!("ROC_FUZZ_INSTRUMENT must be 0 or 1, got {value:?}"),
        Err(_) => true,
    };
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo did not set OUT_DIR"));
    let archive = out_dir.join("libroc_fuzz.a");
    let mut build = Command::new(&roc);
    build
        .arg("build")
        .arg(&source)
        .arg("--target=x64glibc")
        .arg("--opt=speed")
        .arg(format!("--output={}", archive.display()));
    if instrument {
        build.arg("--fuzz");
    }

    let status = build
        .status()
        .unwrap_or_else(|error| panic!("failed to run {:?}: {error}", roc));
    if !status.success() {
        panic!("Roc failed to build {}", source.display());
    }

    emit_link_directives(&out_dir);
}

fn prebuilt_archive() -> Option<PathBuf> {
    let archive = env::var_os("ROC_FUZZ_ARCHIVE")?;
    if env::var_os("ROC_FUZZ_APP").is_some() || env::var_os("ROC_FUZZ_TARGET").is_some() {
        panic!("ROC_FUZZ_ARCHIVE cannot be combined with ROC_FUZZ_APP or ROC_FUZZ_TARGET");
    }
    let path = PathBuf::from(archive);
    if !path.is_absolute() {
        panic!(
            "ROC_FUZZ_ARCHIVE must be an absolute path, got {}",
            path.display()
        );
    }
    if path.extension().and_then(|extension| extension.to_str()) != Some("a") || !path.is_file() {
        panic!(
            "ROC_FUZZ_ARCHIVE must name an existing static archive, got {}",
            path.display()
        );
    }
    Some(path)
}

fn link_archive(source: &Path) {
    println!("cargo:rerun-if-changed={}", source.display());
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo did not set OUT_DIR"));
    let destination = out_dir.join("libroc_fuzz.a");
    fs::copy(source, &destination).unwrap_or_else(|error| {
        panic!(
            "failed to copy {} to {}: {error}",
            source.display(),
            destination.display()
        )
    });
    emit_link_directives(&out_dir);
}

fn emit_link_directives(directory: &Path) {
    println!("cargo:rustc-link-search=native={}", directory.display());
    println!("cargo:rustc-link-lib=static=roc_fuzz");
}

fn source_path() -> PathBuf {
    if let Some(app) = env::var_os("ROC_FUZZ_APP") {
        if env::var_os("ROC_FUZZ_TARGET").is_some() {
            panic!("set ROC_FUZZ_APP or ROC_FUZZ_TARGET, not both");
        }
        let source = PathBuf::from(app);
        if !source.is_absolute() {
            panic!(
                "ROC_FUZZ_APP must be an absolute path, got {}",
                source.display()
            );
        }
        if source.extension().and_then(|extension| extension.to_str()) != Some("roc")
            || !source.is_file()
        {
            panic!(
                "ROC_FUZZ_APP must name an existing .roc file, got {}",
                source.display()
            );
        }
        return source;
    }

    let target = env::var("ROC_FUZZ_TARGET")
        .expect("set ROC_FUZZ_ARCHIVE, ROC_FUZZ_APP, or ROC_FUZZ_TARGET");
    if target.is_empty()
        || !target
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        panic!("ROC_FUZZ_TARGET must be a target name, got {target:?}");
    }
    let source = PathBuf::from("examples").join(format!("{target}.roc"));
    if !source.is_file() {
        panic!(
            "unknown ROC_FUZZ_TARGET {target:?}: {} does not exist",
            source.display()
        );
    }
    source
}

fn watch_roc_sources(source: &Path) {
    let root = source.parent().expect("Roc app path had no parent");
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        let entries = fs::read_dir(&directory)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", directory.display()));
        for entry in entries {
            let entry = entry.unwrap_or_else(|error| {
                panic!(
                    "failed to read an entry in {}: {error}",
                    directory.display()
                )
            });
            let file_type = entry.file_type().unwrap_or_else(|error| {
                panic!("failed to inspect {}: {error}", entry.path().display())
            });
            let path = entry.path();
            if file_type.is_dir() {
                pending.push(path);
            } else if file_type.is_file()
                && path.extension().and_then(|extension| extension.to_str()) == Some("roc")
            {
                println!("cargo:rerun-if-changed={}", path.display());
            }
        }
    }
}

fn read_pin(path: &Path) -> String {
    let contents = fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()));
    let mut lines = contents.lines();
    let pin = lines.next().unwrap_or("").trim();
    if pin.is_empty() || lines.any(|line| !line.trim().is_empty()) {
        panic!(
            "{} must contain exactly one Roc nightly tag",
            path.display()
        );
    }
    pin.to_owned()
}

fn compiler_matches_pin(version: &str, pin: &str) -> bool {
    let reported = version.split_whitespace().last().unwrap_or(version);
    if reported == pin {
        return true;
    }
    let revision = pin.rsplit('-').next().unwrap_or(pin);
    let reported_revision = reported.rsplit('-').next().unwrap_or(reported);
    revision.len() >= 7
        && reported_revision.starts_with(revision)
        && reported_revision
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
}
