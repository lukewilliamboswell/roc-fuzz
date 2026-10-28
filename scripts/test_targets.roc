#!/usr/bin/env roc-stable
app [main!] {
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
}

import cli.Duration
import cli.Env
import cli.Monotonic
import cli.OsStr
import cli.Path
import cli.Stdout
import weaver.Cli
import weaver.Opt
import src/CliValues
import src/Files
import src/Report
import src/RocSource
import src/Script
import src/SkipNotes
import src/WeaverCli

Operation : [All, Build, Check, Fuzz, Seed, Test]

RawCase : { expected_failure : Bool, name : Str, path : Str, seed_hex : Str, skip_fuzz : Bool, skip_seed : Bool }

AllocationStats : { allocs : U64, reallocs : U64, deallocs : U64, requested_bytes : U64, entry_live_allocs : U64, entry_live_bytes : U64, exit_live_allocs : U64, exit_live_bytes : U64, peak_live_bytes : U64 }

Observation : { id : U64, parent_id : U64, name : Str, occurrence : U64, complete : Bool, stats : AllocationStats }

TestCase := { expected_failure : Bool, name : Str, path : Path, seed : List(U8), skip_fuzz : Bool, skip_seed : Bool }.{}

PlatformUrl :: Str.{
	parse = |value| {
		remainder = if Script.starts_with(value, "http://") {
			value.to_utf8().drop_first(7)
		} else if Script.starts_with(value, "https://") {
			value.to_utf8().drop_first(8)
		} else {
			return Err(InvalidPlatformUrl(value))
		}
		authority = Str.from_utf8_lossy(remainder).split_on("/").first().map_err(|_| InvalidPlatformUrl(value))?
		if authority.is_empty() or value.contains(" ") {
			Err(InvalidPlatformUrl(value))
		} else {
			Ok(PlatformUrl.(value))
		}
	}

	to_str = |PlatformUrl.(value)| value
}

main! = |raw_args| {
	cli_options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(parsed) => parsed
		Exit => return Ok({})
	}
	suite_root = Path.absolute!(cli_options.suite_root)?
	inventory = load_inventory!(Path.join(suite_root, "tests/targets.json"))?
	selected = select_targets(cli_options.selected, cli_options.path_prefix, inventory)?
	notes = SkipNotes.load!(Path.join(suite_root, "tests/targets.json"))?
	settings = { max_total_time: cli_options.max_total_time, verbose: cli_options.verbose, campaign: cli_options.campaign_dir }
	roc = Script.roc!()?
	Env.with_temp_dir!(
		|work| {
			cases = match cli_options.platform_url {
				Ok(url) => prepare_platform_tests!(work, selected, url.to_str(), suite_root)?
				Err(NoValue) => selected.map(|item| rebase(item, Path.join(suite_root, Path.display(item.path))))
			}
			run_operation!(cli_options.operation, settings, roc, cases, notes, work)
		},
	)
}

cli_parser = Cli.assert_valid(
	Cli.finish(
		{
			suite_root: Opt.single({ short: "", long: "suite-root", help: "Root containing examples and tests/targets.json. [default: .]", type: "path", parser: CliValues.path, default: Value(Path.utf8(".")) }),
			max_total_time: Opt.u64({ short: "", long: "max-total-time", help: "Seconds allocated to each fuzz target. [default: 5]", default: Value(5) }),
			operation: Opt.single({ short: "", long: "operation", help: "One of check, test, build, seed, fuzz, or all. [default: all]", type: "operation", default: Value(All), parser: parse_operation }),
			platform_url: Opt.maybe({ short: "", long: "platform-url", help: "Rewrite copied examples to use this platform bundle URL.", type: "url", parser: parse_url }),
			selected: Opt.str_list({ short: "", long: "target", help: "Target name to run; repeat for multiple targets." }),
			path_prefix: Opt.maybe_str({ short: "", long: "path-prefix", help: "Run only the targets whose path starts with this prefix, such as tests/targets/builtins/." }),
			verbose: Opt.flag({ short: "v", long: "verbose", help: "Print commands and runner statistics." }),
			campaign_dir: Opt.maybe({ short: "", long: "campaign-dir", help: "Keep each fuzz target's corpus in DIR/corpus/NAME and its failures in DIR/failures/NAME across runs, and fuzz every target before reporting the ones that failed.", type: "path", parser: CliValues.path }),
		}.Cli,
		{
			name: "test-targets",
			version: "development",
			authors: [],
			description: "Check, test, build, or fuzz the repository target inventory.",
			text_style: Plain,
		},
	),
)

parse_operation : _ -> Try(Operation, [InvalidNumStr, InvalidValue(Str), InvalidUtf8])
parse_operation = |argument| CliValues.parse(argument, operation_from_str, "expected check, test, build, seed, fuzz, or all")

operation_from_str = |value|
	match value {
		"all" => Ok(All)
		"build" => Ok(Build)
		"check" => Ok(Check)
		"fuzz" => Ok(Fuzz)
		"seed" => Ok(Seed)
		"test" => Ok(Test)
		other => Err(UnknownOperation(other))
	}

parse_url : _ -> Try(PlatformUrl, [InvalidNumStr, InvalidValue(Str), InvalidUtf8])
parse_url = |argument| CliValues.parse(argument, PlatformUrl.parse, "expected an absolute HTTP or HTTPS URL")

load_inventory! = |path| {
	raw : { cases : List(RawCase) }
	raw = Json.parse(Path.read_utf8!(path)?).map_err(|err| InvalidTestInventory(Path.display(path), err))?
	var $cases = []
	var $names = []
	for item in raw.cases {
		if $names.contains(item.name) {
			return Err(DuplicateTestTarget(item.name))
		}
		$names = $names.append(item.name)
		$cases = $cases.append(
			TestCase.{
				expected_failure: item.expected_failure,
				name: item.name,
				path: Path.utf8(item.path),
				seed: decode_hex(item.seed_hex)?,
				skip_fuzz: item.skip_fuzz,
				skip_seed: item.skip_seed,
			},
		)
	}
	Ok($cases)
}

select_targets = |requested, prefix, available| {
	for name in requested {
		if !available.any(|item| item.name == name) {
			return Err(UnknownTestTarget(name))
		}
	}
	named = if (requested.is_empty()) available else available.keep_if(|item| requested.contains(item.name))
	match prefix {
		Ok(start) => {
			under = named.keep_if(|item| Script.starts_with(Path.display(item.path), start))
			if (under.is_empty()) Err(NoTargetsUnder(start)) else Ok(under)
		}
		Err(NoValue) => Ok(named)
	}
}

## Copy the suite and point every application in it at one platform bundle.
## Targets keep their place under the suite root, so their relative imports of
## sibling modules and helper packages still resolve.
prepare_platform_tests! = |temporary, selected, url, suite_root| {
	for directory in ["examples", "tests"] {
		copied = Path.join(temporary, directory)
		Path.copy_dir!(Path.join(suite_root, directory), copied)?
		for path in Files.roc_files!(copied)? {
			match RocSource.replace_platform_if_present(Path.read_utf8!(path)?, url)? {
				Updated(source) => Path.write_utf8!(path, source)?
				Unchanged => {}
			}
		}
	}
	Ok(selected.map(|item| rebase(item, Path.join(temporary, Path.display(item.path)))))
}

Stage : [Check, Test, Build, Seed, Measure, Quality, Fuzz]

stages_for = |operation|
	match operation {
		Check => [Check]
		Test => [Test]
		Build => [Build]
		Seed => [Build, Seed, Measure, Quality]
		Fuzz => [Build, Fuzz]
		All => [Check, Test, Build, Seed, Measure, Quality, Fuzz]
	}

stage_name = |stage|
	match stage {
		Check => "check"
		Test => "test"
		Build => "build"
		Seed => "seed"
		Measure => "measure"
		Quality => "quality"
		Fuzz => "fuzz"
	}

## Run each stage over every case, printing each step as it finishes and a
## summary at the end. A case that fails a stage is skipped by the stages after
## it; every other case carries on, so one run reports every failure. A switched
## off seed or fuzz run is a skip with its note.
run_operation! = |operation, settings, roc, cases, notes, work| {
	colored = Report.color!()
	started = Monotonic.now!()
	stages = stages_for(operation)
	Stdout.line!("Running ${cases.len().to_str()} cases: ${Str.join_with(stages.map(stage_name), ", ")}")?
	var $steps = []
	var $blocked = []
	for stage in stages {
		var $position = 0
		for item in cases {
			$position = $position + 1
			attempt = if $blocked.contains(item.name) {
				{ outcome: Skip("an earlier step failed"), millis: 0 }
			} else {
				match skip_note(stage, item, notes) {
					Ok(note) => { outcome: Skip(note), millis: 0 }
					Err(NotSkipped) => {
						step_started = Monotonic.now!()
						result = run_step!(stage, settings, roc, item, work)
						millis = Duration.to_millis(Monotonic.elapsed!(step_started))
						match result {
							Ok({}) => { outcome: Pass, millis }
							Err(StepFailed(detail)) => { outcome: Fail(detail), millis }
							Err(other) => { outcome: Fail(Str.inspect(other)), millis }
						}
					}
				}
			}
			step = { stage: stage_name(stage), name: item.name, outcome: attempt.outcome, millis: attempt.millis }
			Stdout.line!(Report.line($position, cases.len(), step, colored))?
			match attempt.outcome {
				Fail(_) => {
					$blocked = $blocked.append(item.name)
				}
				_ => {}
			}
			$steps = $steps.append(step)
		}
	}
	for text in Report.summary($steps, Duration.to_millis(Monotonic.elapsed!(started)), colored) {
		Stdout.line!(text)?
	}
	failed = $steps.keep_if(|step| step.outcome != Pass and !is_skip(step.outcome))
	if (failed.is_empty()) Ok({}) else Err(TargetsFailed(failed.map(|step| "${step.stage} ${step.name}")))
}

is_skip = |outcome|
	match outcome {
		Skip(_) => Bool.True
		_ => Bool.False
	}

## Why `stage` is switched off for `item`, from its note in tests/targets.json.
skip_note = |stage, item, notes|
	match stage {
		Seed | Measure | Quality if item.skip_seed => Ok(SkipNotes.describe(notes, item.name, "seed"))
		Fuzz if item.skip_fuzz => Ok(SkipNotes.describe(notes, item.name, "fuzz"))
		_ => Err(NotSkipped)
	}

executable_path = |work, item| Path.join(Path.join(work, "executables"), item.name)

run_step! = |stage, settings, roc, item, work|
	match stage {
		Check => run_quiet!(settings.verbose, roc, ["check", Path.to_os_str(item.path)], 0)
		Test => run_quiet!(settings.verbose, roc, ["test", Path.to_os_str(item.path)], 0)
		Build => {
			Path.create_all!(Path.join(work, "executables"))?
			run_quiet!(settings.verbose, roc, ["build", "--fuzz", Path.to_os_str(item.path), OsStr.from_str("--output=${Path.display(executable_path(work, item))}")], 0)
		}
		Seed => {
			seed = seed_path!(item, work)?
			executable = Script.command(Path.to_os_str(executable_path(work, item)))
			run_quiet!(settings.verbose, executable, ["show", Path.to_os_str(seed)], 0)?
			run_quiet!(settings.verbose, executable, ["replay", Path.to_os_str(seed)], expected_code(item))
		}
		Measure => measure_step!(roc, item, work)
		Quality => quality_step!(item, work)
		Fuzz => fuzz_step!(settings, item, work)
	}

## A case that is expected to fail must fail the way a target failure does.
expected_code = |item| if (item.expected_failure) 1 else 0

## Run one command of a step and require `expected` as its exit code. The
## output is kept and shown only on failure, so a passing run prints one line
## per step; `--verbose` shows everything as it happens.
run_quiet! : Bool, Script.Command, List(OsStr), I32 => Try({}, _)
run_quiet! = |verbose, command, args, expected| {
	display = Str.join_with([command.program].concat(args).map(OsStr.display), " ")
	if verbose {
		Stdout.line!("$ ${display}")?
		code = Script.exit_code!(command.cmd(args))?
		if (code == expected) Ok({}) else Err(StepFailed("`${display}` exited with code ${code.to_str()}, expected ${expected.to_str()}"))
	} else {
		output = command.output!(args, Path.utf8("."))?
		match output.status {
			Exited(code) if code == expected => Ok({})
			Exited(code) => Err(StepFailed("`${display}` exited with code ${code.to_str()}, expected ${expected.to_str()}\n${tail(output)}"))
			Signaled(signal) => Err(StepFailed("`${display}` ended on signal ${Str.inspect(signal)}\n${tail(output)}"))
		}
	}
}

## The last lines of a command's output, enough to act on a failure.
tail = |output| {
	lines = Str.from_utf8_lossy(output.stdout_bytes.concat(output.stderr_bytes)).split_on("\n").keep_if(|line| !line.is_empty())
	Str.join_with(lines.drop_first(if (lines.len() > 30) lines.len() - 30 else 0), "\n")
}

## Measure the actual property, requiring a completed observation inventory.
## Instrumented and ordinary builds must observe the same allocator statistics.
measure_step! = |roc, item, work| {
	seed = seed_path!(item, work)?
	directory = Path.join(Path.join(work, "measure"), item.name)
	Path.create_all!(directory)?
	executable = Script.command(Path.to_os_str(executable_path(work, item)))
	measure_args = if (item.name == "qualityLateRule")
		["measure", Path.to_os_str(seed), "--report-dir=late-rule-recording"]
	else
		["measure", Path.to_os_str(seed)]
	measured = executable.output!(measure_args, directory)?
	match (item.expected_failure, measured.status) {
		(True, Exited(1)) => {
			if item.name == "qualityLateRule" {
				trace : { metric_valid : Bool, trace_rules_valid : Bool, trace_rules_passed : Bool, complete : Bool }
				trace = Json.parse(Path.read_utf8!(Path.join(directory, "late-rule-recording/example-0-original-trace.json"))?)?
				if !trace.metric_valid or trace.trace_rules_valid or trace.trace_rules_passed or trace.complete {
					return Err(StepFailed("a late trace rule changed allocation validity or lost its unfinished original observation"))
				}
			}
			Ok({})
		}
		(True, _) => Err(StepFailed("measure did not report the expected finding"))
		(False, Exited(0)) => {
			observations : List(Observation)
			observations = Json.parse(Str.from_utf8_lossy(measured.stdout_bytes))?
			if observations.is_empty() or !observations.all(|region| region.complete) or !observations.any(|region| region.name == "$property") {
				return Err(StepFailed("measure returned an incomplete property inventory"))
			}
			plain = Path.join(Path.join(work, "plain"), item.name)
			Path.create_all!(Path.join(work, "plain"))?
			run_quiet!(Bool.False, roc, ["build", Path.to_os_str(item.path), OsStr.from_str("--output=${Path.display(plain)}")], 0)?
			from_plain = Script.command(Path.to_os_str(plain)).output!(["measure", Path.to_os_str(seed)], directory)?
			if from_plain.status != Exited(0) or from_plain.stdout_bytes != measured.stdout_bytes {
				return Err(StepFailed("allocation observations differ when built without --fuzz"))
			}
			Ok({})
		}
		(False, _) => Err(StepFailed("measure failed\n${tail(measured)}"))
	}
}

## The real executable checks and accepts its source-authored inventory.
quality_step! = |item, work| {
	directory = Path.join(Path.join(work, "quality"), item.name)
	Path.create_all!(directory)?
	executable = Script.command(Path.to_os_str(executable_path(work, item)))
	listed = executable.output!(["examples"], directory)?
	if listed.status != Exited(0) {
		return Err(StepFailed("examples failed\n${tail(listed)}"))
	}
	checked = executable.output!(["check", "--report-dir=unbaselined"], directory)?
	if checked.status != Exited(0) {
		return Err(StepFailed("declared examples failed\n${tail(checked)}"))
	}
	if item.name == "qualityLifetimes" {
		report : { examples : List({ observations : List(Observation) }) }
		report = Json.parse(Path.read_utf8!(Path.join(directory, "unbaselined/report.json"))?)?
		expected : AllocationStats
		expected = { allocs: 0, reallocs: 0, deallocs: 0, requested_bytes: 0, entry_live_allocs: 0, entry_live_bytes: 0, exit_live_allocs: 0, exit_live_bytes: 0, peak_live_bytes: 0 }
		if report.examples.len() != 2 or !report.examples.all(|example| example.observations.len() == 1 and example.observations.all(|region| region.name == "$property" and region.stats == expected)) {
			return Err(StepFailed("scalar property measurements included fixture or decoder ownership cleanup"))
		}
	}
	if item.name == "qualityReturnedValues" {
		report : { examples : List({ observations : List(Observation) }) }
		report = Json.parse(Path.read_utf8!(Path.join(directory, "unbaselined/report.json"))?)?
		if report.examples.len() != 2 or !report.examples.all(
			|example| {
				unused = example.observations.keep_if(|region| region.name == "unused observation")
				unused.len() == 1 and unused.all(
					|region| {
						stats = region.stats
						stats.allocs == 1 and stats.reallocs == 0 and stats.deallocs == 0
							and stats.exit_live_allocs == stats.entry_live_allocs + 1
							and stats.exit_live_bytes == stats.entry_live_bytes + stats.requested_bytes
							and stats.peak_live_bytes == stats.exit_live_bytes
					},
				)
			},
		) {
			return Err(StepFailed("an unused measured return was dropped before its observation boundary"))
		}
	}
	if !Script.trim(Str.from_utf8_lossy(listed.stdout_bytes)).is_empty() {
		accepted = executable.output!(["accept", "--report-dir=accept"], directory)?
		if accepted.status != Exited(0) {
			return Err(StepFailed("accept failed\n${tail(accepted)}"))
		}
		matched = executable.output!(["check", "--report-dir=matched"], directory)?
		if matched.status != Exited(0) {
			return Err(StepFailed("accepted observations did not match\n${tail(matched)}"))
		}
		report : { baseline_status : Str }
		report = Json.parse(Path.read_utf8!(Path.join(directory, "matched/report.json"))?)?
		if report.baseline_status != "matched" {
			return Err(StepFailed("baseline was not matched"))
		}
	}
	Ok({})
}

## Fuzz the target for the configured time. In a campaign the corpus outlives
## the run and each failure's input is kept.
fuzz_step! = |settings, item, work| {
	root = match settings.campaign {
		Ok(directory) => Path.absolute!(directory)?
		Err(NoValue) => work
	}
	_ = seed_path!(item, root)?
	base_args = ["run", Path.to_os_str(Path.join(Path.join(root, "corpus"), item.name)), OsStr.from_str("--time=${settings.max_total_time.to_str()}")]
	args = if (settings.verbose) base_args.append("--print-final-stats") else base_args
	full_args = match settings.campaign {
		Ok(_) => {
			report_parent = Path.join(Path.join(root, "reports"), item.name)
			Path.create_all!(report_parent)?
			counter_path = Path.join(report_parent, "next-run")
			counter = if Path.is_file!(counter_path)? {
				U64.from_str(Script.trim(Path.read_utf8!(counter_path)?))?
			} else {
				0
			}
			Path.write_utf8!(counter_path, (counter + 1).to_str())?
			failures = Path.join(report_parent, "run-${counter.to_str()}")
			Path.create_all!(failures)?
			args.append(OsStr.from_str("--report-dir=${Path.display(failures)}"))
		}
		Err(NoValue) => args
	}
	run_quiet!(settings.verbose, Script.command(Path.to_os_str(executable_path(work, item))), full_args, expected_code(item))
}

seed_path! = |item, work| {
	directory : Path
	directory = Path.join(Path.join(work, "corpus"), item.name)
	Path.create_all!(directory)?
	path = Path.join(directory, "seed")
	Path.write_bytes!(path, item.seed)?
	Ok(path)
}

decode_hex = |encoded| {
	bytes = encoded.to_utf8()
	if bytes.len() % 2 != 0 {
		return Err(OddLengthSeedHex)
	}
	var $decoded = []
	var $index = 0
	while $index < bytes.len() {
		first = bytes.get($index)?
		second = bytes.get($index + 1)?
		$decoded = $decoded.append(hex_nibble(first)? * 16 + hex_nibble(second)?)
		$index = $index + 2
	}
	Ok($decoded)
}

hex_nibble = |byte|
	if (byte >= '0' and byte <= '9') Ok(byte - '0')
	else if (byte >= 'a' and byte <= 'f') Ok(byte - 'a' + 10)
	else Err(InvalidSeedHex(byte))

rebase = |item, path| TestCase.{ expected_failure: item.expected_failure, name: item.name, path, seed: item.seed, skip_fuzz: item.skip_fuzz, skip_seed: item.skip_seed }
