#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	roc: "nightly-2026-09-10-a670e34",
}

import cli.OsStr
import cli.Path
import weaver.Cli
import weaver.Opt
import src/ApiDocs
import src/CliValues
import src/Project
import src/Script
import src/WeaverCli
import src/WorkspaceDeps

main! = |raw_args| {
	options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(parsed) => parsed
		Exit => return Ok({})
	}
	root = Project.root!()?
	dependencies = WorkspaceDeps.current
	roc_nightly = Script.roc_nightly!()?

	automation = match options.automation_root {
		Ok(path) => Path.absolute!(path)?
		Err(NoValue) => {
			configured = Script.env_str_or!("ROC_AUTOMATION_ROOT", "")?
			if !configured.is_empty() {
				Path.absolute!(Path.utf8(configured))?
			} else {
				checkout = Path.join(root, ".test-cache/roc-automation-docs/${dependencies.roc_automation.build_docs_revision}")
				if !Path.is_dir!(checkout)? {
					Path.create_all!(Path.join(root, ".test-cache/roc-automation-docs"))?
					Script.command("git").run!(["clone", "--filter=blob:none", OsStr.from_str(dependencies.roc_automation.repository), Path.to_os_str(checkout)])?
					Script.command("git").run!(["-C", Path.to_os_str(checkout), "checkout", "--detach", OsStr.from_str(dependencies.roc_automation.build_docs_revision)])?
				}
				checkout
			}
		}
	}

	actual_revision = Script.trim(Str.from_utf8_lossy(Script.command("git").capture!(["-C", Path.to_os_str(automation), "rev-parse", "HEAD"], root, [])?))
	if actual_revision != dependencies.roc_automation.build_docs_revision {
		return Err(UnexpectedAutomationRevision(Path.display(automation), dependencies.roc_automation.build_docs_revision, actual_revision))
	}

	build_script = Path.join(automation, "actions/build-docs/build_docs.py")
	Script.require_file!(build_script)?
	Script.command("python3").run!([
		Path.to_os_str(build_script),
		"--workspace",
		Path.to_os_str(root),
		"--docs-directory",
		"docs",
		"--entrypoint",
		"index.adoc",
		"--output-directory",
		".docs-out",
		"--pdf-filename",
		"roc-fuzz.pdf",
		"--docs-version",
		OsStr.from_str(options.docs_version),
		"--api-entrypoint",
		"platform/main.roc",
		"--roc-command",
		roc_nightly.program,
	])?

	site = Path.join(root, ".docs-out/site")
	pdf = Path.join(root, ".docs-out/roc-fuzz.pdf")
	ApiDocs.validate!(Path.join(site, "api"))?
	Script.pass!("Documentation created in ${Path.display(site)}; PDF: ${Path.display(pdf)}")
}

cli_parser = Cli.assert_valid(
	Cli.finish(
		{
			automation_root: Opt.maybe({ short: "", long: "automation-root", help: "Use a local checkout at the configured revision; otherwise uses ROC_AUTOMATION_ROOT or the pinned cache.", type: "path", parser: CliValues.path }),
			docs_version: Opt.str({ short: "", long: "docs-version", help: "Version label embedded in the manual. [default: trunk]", default: Value("trunk") }),
		}.Cli,
		{
			name: "build-docs",
			version: "development",
			authors: [],
			description: "Build the manual and Roc API docs using pinned shared automation.",
			text_style: Plain,
		},
	),
)
