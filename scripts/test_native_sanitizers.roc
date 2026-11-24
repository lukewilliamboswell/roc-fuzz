#!/usr/bin/env roc-stable
app [main!] {
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.3/BioPdu7WjVhTB2j1HaomKMi8htxsuwqwr79GbXY5nAUf.tar.zst",
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	deflate: "https://github.com/lukewilliamboswell/roc-deflate/releases/download/0.6.0-rc2/CQoQh2ycoMgMbrkSnQJdsEhWjp67fYrT7hWwgQXynEBy.tar.zst",
	roc: "nightly-2026-11-23-b5c77fc",
	tar: "https://github.com/lukewilliamboswell/roc-tar/releases/download/0.0.3-rc1/8egXmMy7h6TTkRzUmxWygp2GnPe4mBSNGy5Q2ZZYkppu.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc6/CxK9QaRb2VBQn2hKHAmSQ1zFYW2AGNC6XLuDXeHDamZY.tar.zst",
}

import cli.Env
import cli.OsStr
import cli.Path
import src/Archive
import src/Files
import src/Integrity
import src/Project
import src/Script
import src/NativeDeps

main! = |_| {
	root = Project.root!()?
	dependency = NativeDeps.current.libfuzzer
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

	source = Path.join(Path.join(work, "libfuzzer-sys-${dependency.version}"), "libfuzzer")
	_ = Archive.extract_under!(Archive.Format.Tar, archive, "libfuzzer-sys-${dependency.version}/libfuzzer", source, 64 * 1024 * 1024)?
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
		.call!()
}
