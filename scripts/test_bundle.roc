#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	roc: "nightly-2026-09-18-1d982dc",
}

import cli.OsStr
import cli.Env
import cli.Path
import cli.Stderr
import weaver.Cli
import weaver.Param
import src/BundleServer
import src/CliValues
import src/Script
import src/WeaverCli

main! = |raw_args| {
	bundle_path = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(parsed) => parsed
		Exit => return Ok({})
	}
	bundle = Path.absolute!(bundle_path)?
	roc_stable = Script.roc_stable!()?
	filename = smoke_test!(bundle, roc_stable)?
	Script.pass!("Bundle smoke test passed: ${filename}")
}

smoke_test! = |bundle, roc_stable| {
	if !Path.is_file!(bundle)? or !Script.ends_with(Path.display(bundle), ".tar.zst") {
		return Err(ExpectedBundle(Path.display(bundle)))
	}

	filename = Path.filename(bundle).map_ok(Path.display).map_err(|_| InvalidBundlePath(Path.display(bundle)))?
	if Env.platform!().os == MACOS {
		Script.warn!("Skipping bundle execution because the pinned Roc compiler crashes while compiling the target runner on Apple Silicon.")?
		return Ok(filename)
	}
	BundleServer.with!(
		filename,
		Path.read_bytes!(bundle)?,
		|server| {
			child = roc_stable.cmd([
				"--opt=dev",
				"scripts/test_targets.roc",
				"--",
				"--operation",
				"all",
				"--max-total-time",
				"1",
				"--platform-url",
				OsStr.from_str(server.url()),
			]).stdout(Capture).stderr(Capture).spawn!().map_err(|err| BundleTestSpawnFailed(err))?
			output = server.serve_child!(child)?
			match output.status {
				Exited(0) => Ok(filename)
				Exited(code) => {
					Stderr.write_bytes!(output.stdout_bytes)?
					Stderr.write_bytes!(output.stderr_bytes)?
					Err(BundleTestExited(code))
				}
				Signaled(signal) => Err(BundleTestSignaled(signal))
			}
		},
	)
}

cli_parser : Cli.CliParser(Path)
cli_parser = Cli.assert_valid(
	Cli.finish(
		Param.single({
			name: "bundle-path",
			help: "Platform .tar.zst archive to smoke test.",
			type: "path",
			parser: CliValues.path,
			default: NoDefault,
		}),
		{ name: "test-bundle", version: "development", authors: [], description: "Run the repository fuzz-target inventory against a platform bundle.", text_style: Plain },
	),
)
