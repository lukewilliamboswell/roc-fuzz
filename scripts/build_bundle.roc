#!/usr/bin/env roc-stable
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
import weaver.Base exposing [InvalidValue]
import weaver.Cli
import weaver.Opt
import src/CliValues
import src/Files
import src/PlatformInputs
import src/Project
import src/Script
import src/WeaverCli

main! = |raw_args| {
	options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(parsed) => parsed
		Exit => return Ok({})
	}
	root = Project.root!()?
	specs = if options.target_specs.is_empty() Project.target_specs else options.target_specs
	output = Path.absolute!(options.output_dir)?
	roc_nightly = Script.roc_nightly!()?
	bundles = build_bundles!(root, specs, output, options.compression, roc_nightly)?
	for bundle in bundles {
		Script.pass!("Created ${Path.display(bundle)}")?
	}
	Ok({})
}

# GitHub dependency uploads are limited to 100 MiB per file.
max_bundle_bytes : U64
max_bundle_bytes = 104857600

build_bundles! = |root, specs, output, compression, roc_nightly| {
	if compression < 1 or compression > 22 {
		return Err(InvalidCompressionLevel(compression))
	}

	_ = PlatformInputs.validate!(root, specs)?
	Path.create_all!(output)?
	Env.with_temp_dir!(
		|temporary| {
			bundle_root = Path.join(temporary, "platform")
			generated_dir = Path.join(temporary, "bundles")
			Path.create_all!(generated_dir)?
			Path.copy_dir!(Path.join(root, "platform"), bundle_root)?

			# Begin with the complete platform tree, then remove unselected targets.
			for spec in Project.target_specs {
				if !specs.any(|selected| selected.target == spec.target) {
					Path.delete_all!(spec.target.dir(temporary))?
				}
			}

			Path.copy!(Path.join(root, "LICENSE"), Path.join(bundle_root, "LICENSE"))?
			Path.copy!(Path.join(root, "THIRD_PARTY_LICENSES.md"), Path.join(bundle_root, "THIRD_PARTY_LICENSES.md"))?
			files = Files.files!(bundle_root)?
			prefix_len = Path.display(bundle_root).to_utf8().len() + 1
			relative_files = files.map(|path| OsStr.from_str(Str.from_utf8_lossy(Path.display(path).to_utf8().drop_first(prefix_len))))
			roc_nightly.cmd(
				[
					"bundle",
				].concat(relative_files).concat([
					"--output-dir",
					Path.to_os_str(generated_dir),
					"--compression",
					OsStr.from_str(compression.to_str()),
				]),
			).cwd(bundle_root).exec_cmd!()?

			generated = Files.direct_files!(generated_dir)?.keep_if(|path| Script.ends_with(Path.display(path), ".tar.zst"))
			if generated.is_empty() {
				return Err(BundleWasNotProduced)
			}

			var $published = []
			for bundle in generated {
				if Path.size_in_bytes!(bundle)? > max_bundle_bytes {
					return Err(BundleExceedsDependencyLimit(Path.display(bundle), max_bundle_bytes))
				}
				filename = Path.filename(bundle).map_ok(Path.display).map_err(|_| InvalidBundlePath(Path.display(bundle)))?
				destination = Path.join(output, filename)
				Path.copy!(bundle, destination)?
				$published = $published.append(destination)
			}
			Ok($published)
		},
	)
}

BundleOptions : { compression : U64, output_dir : Path, target_specs : List(Project.TargetSpec) }

cli_parser : Cli.CliParser(BundleOptions)
cli_parser = Cli.assert_valid(
	Cli.finish(
		{
			compression: Opt.u64({ short: "", long: "compression", help: "Zstandard compression level. [default: 19]", default: Value(19) }),
			output_dir: Opt.single({ short: "o", long: "output-dir", help: "Directory for the package archive. [default: dist]", type: "path", parser: CliValues.path, default: Value(Path.utf8("dist")) }),
			target_specs: Opt.list({
				short: "",
				long: "target",
				help: "Generated target to include; repeat for multiple targets.",
				type: "target",
				parser: parse_target_spec_arg,
			}),
		}.Cli,
		{
			name: "build-bundle",
			version: "development",
			authors: [],
			description: "Create a validated roc-fuzz platform bundle.",
			text_style: Plain,
		},
	),
)

parse_target_spec_arg = |argument|
	match CliValues.parse(argument, Project.Target.parse, "unknown platform target") {
		Ok(target) => Ok(target.spec())
		Err(err) => Err(err)
	}
