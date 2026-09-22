#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	roc: "nightly-2026-09-18-1d982dc",
}

import cli.Env
import cli.OsStr
import cli.Path
import src/Files
import src/Integrity
import src/Project
import src/Script
import src/WorkspaceDeps

main! = |_| {
	root = Project.root!()?
	dependency = WorkspaceDeps.current.libfuzzer
	compiler = Script.env_str_or!("CXX", "clang++")?
	Env.with_temp_dir!(|work| run_sanitizer_smoke!(root, work, dependency, compiler))?
	Script.pass!("Pinned libFuzzer completed its AddressSanitizer smoke campaign.")
}

run_sanitizer_smoke! = |root, work, dependency, compiler| {
	archive = Path.join(work, "libfuzzer-sys-${dependency.version}.crate")
	Script.info!("DOWNLOAD", "fetching pinned libFuzzer ${dependency.version}")?
	Script.command("curl").run!([
		"--fail",
		"--location",
		"--silent",
		"--show-error",
		"--output",
		Path.to_os_str(archive),
		OsStr.from_str(dependency.url),
	])?
	actual = Integrity.digest!(archive)?
	expected = dependency.sha256.to_str()
	if actual != expected {
		return Err(LibfuzzerChecksumMismatch(expected, actual))
	}

	Script.command("tar").run!(["-xzf", Path.to_os_str(archive), "-C", Path.to_os_str(work)])?
	source = Path.join(Path.join(work, "libfuzzer-sys-${dependency.version}"), "libfuzzer")
	Script.require_file!(Path.join(source, "FuzzerMain.cpp"))?
	cpps = Files.direct_files!(source)?.keep_if(|path| Script.ends_with(Path.display(path), ".cpp"))
	Script.require!(!cpps.is_empty(), "pinned libFuzzer archive contains no C++ sources")?

	executable = Path.join(work, "libfuzzer-sanitizer-smoke")
	harness = Path.join(root, "tests/native/libfuzzer_smoke.cpp")
	Script.require_file!(harness)?
	compile_args = [
		"-std=c++17",
		"-O1",
		"-g",
		"-fno-omit-frame-pointer",
		"-fsanitize=address",
	].concat(cpps.map(Path.to_os_str)).concat([
		Path.to_os_str(harness),
		"-o",
		Path.to_os_str(executable),
	])
	Script.command(OsStr.from_str(compiler)).run!(compile_args)?

	corpus = Path.join(work, "corpus")
	Path.create_all!(corpus)?
	Path.write_bytes!(Path.join(corpus, "seed"), [114, 111, 99, 45, 102, 117, 122, 122, 0, 110, 97, 116, 105, 118, 101, 255])?
	Script.info!("RUN", "AddressSanitizer smoke campaign")?
	executable_args = ["-runs=1000", "-max_len=4096", Path.to_os_str(corpus)]
	Script.command(Path.to_os_str(executable))
		.cmd(executable_args)
		.env("ASAN_OPTIONS", "detect_leaks=1:halt_on_error=1:strict_string_checks=1")
		.exec_cmd!()
}
