#!/usr/bin/env roc-stable
app [main!] {
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.3/BioPdu7WjVhTB2j1HaomKMi8htxsuwqwr79GbXY5nAUf.tar.zst",
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-18-a520eed",
}

import cli.Env
import cli.OsStr
import cli.Path
import src/Script

## Native engines and actual supervised process lifecycle, without Roc fixtures.
main! = |_args| {
	zig = Script.command("zig")
	zig.run!(["test", "src/allocation_bookkeeping.zig", "-lc"])?
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
