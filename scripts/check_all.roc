#!/usr/bin/env roc-stable
app [main!] {
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import cli.OsStr
import cli.Path
import src/Script
import src/Files

main! = |_args| {
	stable = Script.roc_stable!()?
	roc = Script.roc!()?
	check_tooling!(stable)?
	check_platform!(roc)?
	check_fuzz_targets!()?
	check_worktree!()?
	Script.pass!("Repository checks completed successfully.")
}

check_tooling! = |stable| {
	Script.info!("CHECK", "Formatting, tests, and compilation for repository tooling")?
	(Script.roc_stable!()?).run!(["scripts/tooling_integration_tests.roc"])?
	script_files = Files.roc_files!("scripts")?
	stable.run!(["fmt", "--check"].concat(script_files.map(Path.to_os_str)))?
	for test_file in ["scripts/tooling_tests.roc", "scripts/check_supply_chain.roc", "scripts/build_release_sbom.roc", "scripts/render_release_notes.roc"] {
		stable.run!(["test", test_file])?
	}
	app_files = Files.direct_files!("scripts")?.keep_if(|path| Path.ext(path).map_ok(Path.display) == Ok("roc"))
	for path in app_files {
		stable.run!(["check", Path.to_os_str(path)])?
	}
	(Script.roc_stable!()?).run!(["scripts/check_supply_chain.roc"])
}

check_platform! = |roc| {
	Script.info!("CHECK", "Formatting and type-checking the platform with the latest nightly")?
	roc.run!(["fmt", "--check", "platform", "examples", "tests", "trophy-case"])?
	roc.run!(["check", "platform/main.roc"])?
	check_repros!(roc)
}

## A repro under trophy-case/ that can run is a case in tests/targets.json. The
## one kept here is a deliberate type error that the compiler used to panic on:
## it must be reported as an error, which `roc check` does with exit code 1.
check_repros! = |roc| {
	repro = "trophy-case/repros/postcheck_panic_on_type_error.roc"
	Script.info!("RUN", "roc check ${repro} (expecting a reported type error)")?
	code = Script.exit_code!(roc.cmd(["check", OsStr.from_str(repro)]))?
	Script.require!(code == 1, "roc check ${repro} exited with code ${code.to_str()}; it must report the type error and exit with 1")
}

check_fuzz_targets! = || {
	Script.info!("CHECK", "Type-checking every fuzz target in tests/targets.json")?
	(Script.roc_stable!()?).run!(["scripts/test_targets.roc", "--", "--operation", "check"])
}

check_worktree! = || {
	Script.info!("CHECK", "Looking for whitespace errors in the Git diff")?
	Script.command("git").run!(["diff", "--check"])
}
