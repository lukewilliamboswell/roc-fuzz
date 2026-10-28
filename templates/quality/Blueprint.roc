# Ordinary tasks and an ordered workflow; every program is a pinned download.
app [config] { pf: platform "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.8.0/FbJymjYdCxx9vqMcau7r4tQfeAbnVGqqJoYrLGqPCqKu.tar.zst" }

import pf.Recipes

config = [
	Name("my-quality-target"),
	Systems(["x86_64-linux", "aarch64-darwin"]),
	Environment(
		"dev",
		[
			Programs([Fetch("roc", Recipes.roc_nightly("nightly-2026-10-27-de79a0f"))]),
		],
	),
	Task("build", [Use("dev"), Run(["roc", "build", "--fuzz", "fuzz.roc"])]),
	Task("check", [Use("dev"), Run(["./fuzz", "check"])]),
	Task("run", [Use("dev"), Run(["./fuzz", "run"])]),
	# Acceptance is an explicit maintainer action, separate from verification.
	Task("accept", [Use("dev"), Run(["./fuzz", "accept"])]),
	Workflow(
		"verify",
		[
			RunTask("build", []),
			RunTask("check", []),
			RunTask("run", ["--report-dir=.roc-fuzz/verify"]),
		],
	),
]
