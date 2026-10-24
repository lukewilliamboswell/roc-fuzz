#!/usr/bin/env roc-stable
app [main!] {
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
}

import cli.Env
import cli.OsStr
import cli.Path
import weaver.Cli
import weaver.Opt
import src/CliValues
import src/Files
import src/RocSource
import src/Script
import src/SkipNotes
import src/WeaverCli

Operation : [All, Build, Check, Fuzz, Seed, Test]

RawCase : { expected_failure : Bool, name : Str, path : Str, seed_hex : Str, skip_fuzz : Bool, skip_seed : Bool }

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

## A switched-off part of a case is never silent: every run names it, with the
## reason and the issue that will switch it back on.
report_skips! = |selected, notes| {
	Script.info!("SUITE", "${selected.len().to_str()} targets")?
	for item in selected {
		for (skipped, operation) in [(item.skip_seed, "seed"), (item.skip_fuzz, "fuzz")] {
			if skipped {
				Script.warn!("SKIP ${item.name} ${operation}: ${SkipNotes.describe(notes, item.name, operation)}")?
			}
		}
	}
	Ok({})
}

main! = |raw_args| {
	cli_options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(parsed) => parsed
		Exit => return Ok({})
	}
	suite_root = Path.absolute!(cli_options.suite_root)?
	inventory = load_inventory!(Path.join(suite_root, "tests/targets.json"))?
	selected = select_targets(cli_options.selected, inventory)?
	notes = SkipNotes.load!(Path.join(suite_root, "tests/targets.json"))?
	report_skips!(selected, notes)?
	roc = Script.roc!()?
	Env.with_temp_dir!(
		|work| {
			match cli_options.platform_url {
				Ok(url) => {
					local = prepare_platform_tests!(work, selected, url.to_str(), suite_root)?
					run_operation!(cli_options.operation, cli_options.max_total_time, cli_options.verbose, cli_options.campaign_dir, roc, local, work)
				}
				Err(NoValue) => run_operation!(cli_options.operation, cli_options.max_total_time, cli_options.verbose, cli_options.campaign_dir, roc, selected.map(|item| rebase(item, Path.join(suite_root, Path.display(item.path)))), work)
			}
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

select_targets = |requested, available| {
	if requested.is_empty() {
		return Ok(available)
	}
	for name in requested {
		if !available.any(|item| item.name == name) {
			return Err(UnknownTestTarget(name))
		}
	}
	Ok(available.keep_if(|item| requested.contains(item.name)))
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

run_operation! = |operation, max_total_time, verbose, campaign, roc, selected, work|
	match operation {
		Check => check_targets!(roc, selected)
		Test => test_targets!(roc, selected)
		Build => build_targets!(roc, selected, work).map_ok(|_| {})
		Seed => replay_seeds!(build_targets!(roc, selected, work)?, work)
		Fuzz => fuzz_targets!(build_targets!(roc, selected, work)?, max_total_time, verbose, campaign, work)
		All => {
			check_targets!(roc, selected)?
			test_targets!(roc, selected)?
			executables = build_targets!(roc, selected, work)?
			replay_seeds!(executables, work)?
			fuzz_targets!(executables, max_total_time, verbose, campaign, work)
		}
	}

check_targets! = |roc, selected| {
	for item in selected {
		run_allow_pin_warning!(roc, ["check", Path.to_os_str(item.path)])?
	}
	Ok({})
}

test_targets! = |roc, selected| {
	for item in selected {
		run_allow_pin_warning!(roc, ["test", Path.to_os_str(item.path)])?
	}
	Ok({})
}

build_targets! = |roc, selected, work| {
	directory : Path
	directory = Path.join(work, "executables")
	Path.create_all!(directory)?
	var $executables = []
	for item in selected {
		output = Path.join(directory, item.name)
		run_allow_pin_warning!(roc, ["build", "--fuzz", Path.to_os_str(item.path), OsStr.from_str("--output=${Path.display(output)}")])?
		$executables = $executables.append((item, output))
	}
	Ok($executables)
}

run_allow_pin_warning! : Script.Command, List(OsStr) => Try({}, _)
run_allow_pin_warning! = |roc, args| {
	Script.info!("RUN", Str.join_with([roc.program].concat(args).map(OsStr.display), " "))?
	code = Script.exit_code!(roc.cmd(args))?
	# Roc returns 2 for a version-mismatch warning. The examples archives of
	# releases up to 0.4.3 pin every example to the compiler of their day, so
	# the nightly workflow meets that warning until a later release is the
	# latest. The application itself still checked successfully.
	if (code == 0 or code == 2) Ok({}) else Err(RocCommandExited(code))
}

replay_seeds! = |executables, work| {
	for (item, executable) in executables {
		if !item.skip_seed {
			seed = seed_path!(item, work)?
			Script.command(Path.to_os_str(executable)).run!(["show", Path.to_os_str(seed)])?
			run_expectation!(item, executable, ["replay", Path.to_os_str(seed)])?
		}
	}
	Ok({})
}

## Fuzz each target for `seconds`. In a campaign the corpus outlives the run,
## each failure's input is kept, and one target's failure does not stop the rest.
fuzz_targets! = |executables, seconds, verbose, campaign, work| {
	root = match campaign {
		Ok(directory) => Path.absolute!(directory)?
		Err(NoValue) => work
	}
	var $failed = []
	for (item, executable) in executables {
		if !item.skip_fuzz {
			_ = seed_path!(item, root)?
			base_args = ["run", Path.to_os_str(Path.join(Path.join(root, "corpus"), item.name)), OsStr.from_str("--time=${seconds.to_str()}")]
			args = if (verbose) base_args.append("--print-final-stats") else base_args
			match campaign {
				Ok(_) => {
					failures = Path.join(Path.join(root, "failures"), item.name)
					Path.create_all!(failures)?
					match run_expectation!(item, executable, args.append(OsStr.from_str("--artifact-dir=${Path.display(failures)}"))) {
						Ok({}) => {}
						Err(err) => {
							Script.warn!("${item.name} failed: ${Str.inspect(err)}")?
							$failed = $failed.append(item.name)
						}
					}
				}
				Err(NoValue) => run_expectation!(item, executable, args)?
			}
		}
	}
	if ($failed.is_empty()) Ok({}) else Err(CampaignTargetsFailed($failed))
}

run_expectation! = |item, executable, args| {
	if item.expected_failure {
		code = Script.exit_code!(Script.command(Path.to_os_str(executable)).cmd(args))?
		if (code == 77) Ok({}) else Err(ExpectedTargetFailure(item.name, code))
	} else {
		Script.command(Path.to_os_str(executable)).run!(args)
	}
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
