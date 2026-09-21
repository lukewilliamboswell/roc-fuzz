#!/usr/bin/env -S roc-nightly --opt=interpreter
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	roc: "nightly-2026-09-19-d025939",
}

import cli.Env
import cli.OsStr
import cli.Path
import cli.Url
import weaver.Cli
import weaver.Opt
import src/CliValues
import src/Files
import src/RocSource
import src/Script
import src/WeaverCli

Operation : [All, Build, Check, Fuzz, Seed, Test]

RawCase : { expected_failure : Bool, name : Str, path : Str, seed_hex : Str, skip_fuzz : Bool, skip_seed : Bool }

TestCase := { expected_failure : Bool, name : Str, path : Path, seed : List(U8), skip_fuzz : Bool, skip_seed : Bool }.{}

main! = |raw_args| {
	cli_options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(parsed) => parsed
		Exit => return Ok({})
	}
	inventory = load_inventory!("tests/targets.json")?
	selected = select_targets(cli_options.selected, inventory)?
	roc_nightly = Script.roc_nightly!()?
	match cli_options.platform_url {
		Ok(url) => Env.with_temp_dir!(
			|temporary| {
				local = prepare_platform_tests!(temporary, selected, Url.to_str(url))?
				run_operation!(cli_options.operation, cli_options.max_total_time, cli_options.verbose, roc_nightly, local)
			},
		)
		Err(NoValue) => run_operation!(cli_options.operation, cli_options.max_total_time, cli_options.verbose, roc_nightly, selected)
	}
}

cli_parser = Cli.assert_valid(
	Cli.finish(
		{
			max_total_time: Opt.u64({ short: "", long: "max-total-time", help: "Seconds allocated to each fuzz target. [default: 5]", default: Value(5) }),
			operation: Opt.single({ short: "", long: "operation", help: "One of check, test, build, seed, fuzz, or all. [default: all]", type: "operation", default: Value(All), parser: parse_operation }),
			platform_url: Opt.maybe({ short: "", long: "platform-url", help: "Rewrite copied examples to use this platform bundle URL.", type: "url", parser: parse_url }),
			selected: Opt.str_list({ short: "", long: "target", help: "Target name to run; repeat for multiple targets." }),
			verbose: Opt.flag({ short: "v", long: "verbose", help: "Print commands and runner statistics." }),
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

parse_url : _ -> Try(Url, [InvalidNumStr, InvalidValue(Str), InvalidUtf8])
parse_url = |argument| CliValues.parse(argument, Url.parse, "expected an absolute HTTP or HTTPS URL")

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

prepare_platform_tests! = |temporary, selected, url| {
	example_root = Path.join(temporary, "examples")
	Path.copy_dir!("examples", example_root)?
	Path.copy_dir!("tests", Path.join(temporary, "tests"))?
	for path in Files.roc_files!(example_root)? {
		match RocSource.replace_platform_if_present(Path.read_utf8!(path)?, url)? {
			Updated(source) => Path.write_utf8!(path, source)?
			Unchanged => {}
		}
	}
	selected.map_try(
		|item| Ok(
			TestCase.{
				expected_failure: item.expected_failure,
				name: item.name,
				path: Path.join(example_root, examples_relative(item.path)?),
				seed: item.seed,
				skip_fuzz: item.skip_fuzz,
				skip_seed: item.skip_seed,
			},
		),
	)
}

run_operation! = |operation, max_total_time, verbose, roc_nightly, selected|
	match operation {
		Check => check_targets!(roc_nightly, selected)
		Test => test_targets!(roc_nightly, selected)
		Build => build_targets!(roc_nightly, selected).map_ok(|_| {})
		Seed => replay_seeds!(build_targets!(roc_nightly, selected)?)
		Fuzz => fuzz_targets!(build_targets!(roc_nightly, selected)?, max_total_time, verbose)
		All => {
			check_targets!(roc_nightly, selected)?
			test_targets!(roc_nightly, selected)?
			executables = build_targets!(roc_nightly, selected)?
			replay_seeds!(executables)?
			fuzz_targets!(executables, max_total_time, verbose)
		}
	}

check_targets! = |roc_nightly, selected| {
	roc_nightly.run!(["fmt", "--check", "platform", "examples"])?
	for item in selected {
		run_allow_pin_warning!(roc_nightly, ["check", Path.to_os_str(item.path), "--no-cache"])?
	}
	Ok({})
}

test_targets! = |roc_nightly, selected| {
	for item in selected {
		run_allow_pin_warning!(roc_nightly, ["test", Path.to_os_str(item.path), "--no-cache"])?
	}
	Ok({})
}

build_targets! = |roc_nightly, selected| {
	directory : Path
	directory = ".test-cache/executables"
	Path.create_all!(directory)?
	var $executables = []
	for item in selected {
		output = Path.join(directory, item.name)
		run_allow_pin_warning!(roc_nightly, ["build", "--fuzz", Path.to_os_str(item.path), OsStr.from_str("--output=${Path.display(output)}")])?
		$executables = $executables.append((item, output))
	}
	Ok($executables)
}

run_allow_pin_warning! : Script.Command, List(OsStr) => Try({}, _)
run_allow_pin_warning! = |roc_nightly, args| {
	Script.info!("RUN", Str.join_with([roc_nightly.program].concat(args).map(OsStr.display), " "))?
	code = roc_nightly.cmd(args).exec_exit_code!()?
	# Roc currently returns 2 when checking an app whose downloaded platform
	# carries an older compiler pin; the app itself still checked successfully.
	if code == 0 or code == 2 Ok({}) else Err(RocCommandExited(code))
}

replay_seeds! = |executables| {
	for (item, executable) in executables {
		if !item.skip_seed {
			seed = seed_path!(item)?
			Script.command(Path.to_os_str(executable)).run!(["show", Path.to_os_str(seed)])?
			run_expectation!(item, executable, ["replay", Path.to_os_str(seed)])?
		}
	}
	Ok({})
}

fuzz_targets! = |executables, seconds, verbose| {
	for (item, executable) in executables {
		if !item.skip_fuzz {
			seed = seed_path!(item)?
			base_args = ["run", Path.to_os_str(seed), OsStr.from_str("--time=${seconds.to_str()}")]
			args = if verbose base_args.append("--print-final-stats") else base_args
			run_expectation!(item, executable, args)?
		}
	}
	Ok({})
}

run_expectation! = |item, executable, args| {
	if item.expected_failure {
		code = Script.command(Path.to_os_str(executable)).cmd(args).exec_exit_code!()?
		if code == 77 Ok({}) else Err(ExpectedTargetFailure(item.name, code))
	} else {
		Script.command(Path.to_os_str(executable)).run!(args)
	}
}

seed_path! = |item| {
	directory : Path
	directory = ".test-cache/corpus/${item.name}"
	Path.create_all!(directory)?
	path = Path.join(directory, "seed")
	Path.write_bytes!(path, item.seed)?
	Ok(path)
}

examples_relative = |path| {
	prefix = "examples/"
	text = Path.display(path)
	if !Script.starts_with(text, prefix) {
		return Err(TestTargetOutsideExamples(text))
	}
	Ok(Str.from_utf8_lossy(text.to_utf8().drop_first(prefix.to_utf8().len())))
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
	if byte >= '0' and byte <= '9' Ok(byte - '0')
	else if byte >= 'a' and byte <= 'f' Ok(byte - 'a' + 10)
	else Err(InvalidSeedHex(byte))
