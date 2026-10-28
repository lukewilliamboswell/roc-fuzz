#!/usr/bin/env roc-stable
app [main!] {
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import cli.Env
import cli.OsStr
import cli.Path
import src/Script

## Native engines and actual supervised process lifecycle, without Roc fixtures.
main! = |_args| {
	zig = Script.command("zig")
	zig.run!(["test", "src/observation.zig", "-lc"])?
	zig.run!(["test", "src/quality_runner.zig", "-lc"])?
	Env.with_temp_dir!(
		|temporary| {
			fixture = Path.join(temporary, "quality-runner-fixture")
			zig.run!(["build-exe", "--dep", "quality_runner", "-Mroot=tests/native/quality_runner_fixture.zig", "-Mquality_runner=src/quality_runner.zig", "-lc", OsStr.from_str("-femit-bin=${Path.display(fixture)}")])?
			zig.run!(["run", "tests/native/quality_runner_integration.zig", "-lc", "--", Path.to_os_str(fixture)])
		},
	)?
	Script.pass!("Allocation, trace, baseline and supervisor lifecycle tests passed.")
}
