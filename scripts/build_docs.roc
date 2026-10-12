#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	roc: "nightly-2026-09-29-7f11a82",
}

import cli.OsStr
import cli.Path
import weaver.Cli
import weaver.Opt
import src/ApiDocs
import src/CliValues
import src/Identity
import src/Project
import src/Script
import src/WeaverCli

main! = |raw_args| {
	options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(parsed) => parsed
		Exit => return Ok({})
	}
	root = Project.root!()?
	revision = build_docs_revision!(root)?
	roc = Script.roc!()?

	automation = match options.automation_root {
		Ok(path) => Path.absolute!(path)?
		Err(NoValue) => {
			configured = Script.env_str_or!("ROC_AUTOMATION_ROOT", "")?
			if !configured.is_empty() {
				Path.absolute!(Path.utf8(configured))?
			} else {
				checkout = Path.join(root, ".test-cache/roc-automation-docs/${revision}")
				if !Path.is_dir!(checkout)? {
					Path.create_all!(Path.join(root, ".test-cache/roc-automation-docs"))?
					Script.command("git").run!(["clone", "--filter=blob:none", "https://github.com/lukewilliamboswell/roc-automation.git", Path.to_os_str(checkout)])?
					Script.command("git").run!(["-C", Path.to_os_str(checkout), "checkout", "--detach", OsStr.from_str(revision)])?
				}
				checkout
			}
		}
	}

	actual_revision = Script.trim(Str.from_utf8_lossy(Script.command("git").capture!(["-C", Path.to_os_str(automation), "rev-parse", "HEAD"], root, [])?))
	if actual_revision != revision {
		return Err(UnexpectedAutomationRevision(Path.display(automation), revision, actual_revision))
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
		roc.program,
	])?

	site = Path.join(root, ".docs-out/site")
	pdf = Path.join(root, ".docs-out/roc-fuzz.pdf")
	ApiDocs.validate!(Path.join(site, "api"))?
	Script.pass!("Documentation created in ${Path.display(site)}; PDF: ${Path.display(pdf)}")
}

## The reviewed roc-automation commit is written once, where docs.yml pins the
## shared renderer. A local build uses that same commit.
build_docs_revision! = |root| {
	workflow = Path.read_utf8!(Path.join(root, ".github/workflows/docs.yml"))?
	match Str.split_on(workflow, "lukewilliamboswell/roc-automation/actions/build-docs@") {
		[_, rest] => match Str.split_on(rest, " ") {
			[revision, ..] if Identity.GitRevision.parse(revision) |> Try.is_ok => Ok(revision)
			_ => Err(DocsWorkflowMustPinSharedRenderer)
		}
		_ => Err(DocsWorkflowMustPinSharedRenderer)
	}
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
