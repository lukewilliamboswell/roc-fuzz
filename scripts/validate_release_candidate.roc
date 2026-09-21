#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	roc: "nightly-2026-09-19-d025939",
}

import src/Identity
import src/ReleaseCandidate
import src/Script

main! = |_args| {
	version_text = Script.env_str!("RELEASE_VERSION")?
	expected_text = Script.env_str!("EXPECTED_SHA")?
	actual_text = Script.env_str!("GITHUB_SHA")?
	event = Script.env_str!("GITHUB_EVENT_NAME")?
	ref = Script.env_str!("GITHUB_REF")?

	if event != "workflow_dispatch" or !Script.starts_with(ref, "refs/heads/") {
		return Err(ReleaseCandidateRequiresManualBranchDispatch(event, ref))
	}
	version = ReleaseCandidate.parse(version_text)?
	expected = Identity.GitRevision.parse(expected_text)?
	actual = Identity.GitRevision.parse(actual_text)?
	if expected != actual {
		return Err(ReleaseCandidateShaMismatch(expected.to_str(), actual.to_str()))
	}

	head_text = Script.trim(Str.from_utf8_lossy(Script.command("git").capture!(["rev-parse", "HEAD"], ".", [])?))
	head = Identity.GitRevision.parse(head_text)?
	if head != expected {
		return Err(CheckoutDoesNotMatchReleaseCandidate(expected.to_str(), head.to_str()))
	}

	Script.pass!("Release candidate ${ReleaseCandidate.to_str(version)} at ${expected.to_str()}")
}
