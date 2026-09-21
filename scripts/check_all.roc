#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	roc: "nightly-2026-09-10-a670e34",
}

import cli.Path
import cli.Env
import src/Script
import src/Files

main! = |_args| {
	stable = Script.roc_stable!()?
	nightly = Script.roc_nightly!()?
	check_tooling!(stable, nightly)?
	check_platform!(nightly)?
	if Env.platform!().os == MACOS {
		Script.warn!("Skipping target-runner execution because the pinned Roc compiler crashes while compiling it on Apple Silicon.")?
	} else {
		check_fuzz_targets!(nightly)?
	}
	check_worktree!()?
	Script.pass!("Repository checks completed successfully.")
}

check_tooling! = |stable, nightly| {
	Script.info!("CHECK", "Formatting, tests, and compilation for repository tooling")?
	script_files = Files.roc_files!("scripts")?
	stable.run!(["fmt", "--check"].concat(script_files.map(Path.to_os_str)))?
	for test_file in ["scripts/tooling_tests.roc", "scripts/check_supply_chain.roc", "scripts/build_release_sbom.roc", "scripts/validate_release_candidate.roc"] {
		stable.run!(["test", test_file])?
	}
	app_files = Files.direct_files!("scripts")?.keep_if(|path| Path.ext(path).map_ok(Path.display) == Ok("roc"))
	for path in app_files {
		compiler = if Script.ends_with(Path.display(path), "scripts/test_targets.roc") nightly else stable
		compiler.run!(["check", Path.to_os_str(path)])?
	}
	stable.run!(["scripts/check_supply_chain.roc"])
}

check_platform! = |nightly| {
	Script.info!("CHECK", "Formatting and type-checking the platform with the pinned nightly")?
	nightly.run!(["fmt", "--check", "platform", "examples"])?
	nightly.run!(["check", "platform/main.roc"])
}

check_fuzz_targets! = |nightly| {
	Script.info!("CHECK", "Type-checking every fuzz target in tests/targets.json")?
	nightly.run!(["--opt=dev", "scripts/test_targets.roc", "--", "--operation", "check"])
}

check_worktree! = || {
	Script.info!("CHECK", "Looking for whitespace errors in the Git diff")?
	Script.command("git").run!(["diff", "--check"])
}
