#!/usr/bin/env python3
"""Validate, build, seed, and smoke-test self-contained roc-fuzz targets."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import tempfile
from contextlib import contextmanager
from pathlib import Path

from platform_inputs import validate_platform_inputs


ROOT = Path(__file__).resolve().parents[1]
SPEC_PATH = ROOT / "scripts" / "test_spec.json"
CACHE = ROOT / ".test-cache" / "self-contained"
STAGES = ("check", "test", "build", "seed", "fuzz")
OPERATIONS = ("all", "validate", *STAGES)
REQUIRED_TARGET_KEYS = {"name", "path", "seed_hex", "libfuzzer_seed"}
OPTIONAL_TARGET_KEYS = {"expected_failure", "skip"}
GITHUB_ISSUE = re.compile(r"https://github\.com/[^/]+/[^/]+/issues/[1-9][0-9]*$")
SINGLE_FILE_COLLECTIONS = {"examples", "examples/builtins"}
PLATFORM_DECLARATION = re.compile(r'\bplatform\s+"[^"]+"')


class TestFailure(RuntimeError):
    pass


def run(
    command: list[str],
    *,
    cwd: Path = ROOT,
    verbose: bool = False,
    capture: bool = False,
) -> subprocess.CompletedProcess[str]:
    if verbose:
        print("+", " ".join(command), flush=True)
    completed = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )
    if completed.returncode != 0:
        detail = f"\n{completed.stdout}" if capture and completed.stdout else ""
        raise TestFailure(
            f"command exited with {completed.returncode}: {' '.join(command)}{detail}"
        )
    return completed


def load_targets(selected: list[str]) -> list[dict[str, object]]:
    document = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    if set(document) != {"targets", "retired"}:
        raise TestFailure("test_spec.json must contain exactly targets and retired")

    targets = document["targets"]
    if not isinstance(targets, list) or not all(
        isinstance(target, dict) for target in targets
    ):
        raise TestFailure("targets must be an array of objects")

    for target in targets:
        keys = set(target)
        if not REQUIRED_TARGET_KEYS <= keys or keys - REQUIRED_TARGET_KEYS - OPTIONAL_TARGET_KEYS:
            raise TestFailure(
                "target must contain name, path, seed_hex, and libfuzzer_seed; "
                "only expected_failure and skip are optional"
            )
        name = target["name"]
        path = target["path"]
        seed_hex = target["seed_hex"]
        libfuzzer_seed = target["libfuzzer_seed"]
        if not isinstance(name, str) or not name:
            raise TestFailure("every target needs a non-empty name")
        if not isinstance(path, str):
            raise TestFailure(f"{name}: path must be a string")
        app_path = Path(path)
        expected_name = app_path.parent.name if app_path.name == "main.roc" else app_path.stem
        if name != expected_name:
            raise TestFailure(
                f"{name}: target name must match its file or app directory"
            )
        if not isinstance(seed_hex, str) or not seed_hex or len(seed_hex) % 2:
            raise TestFailure(f"{name}: seed_hex must be non-empty, even-length hex")
        try:
            bytes.fromhex(seed_hex)
        except ValueError as error:
            raise TestFailure(f"{name}: seed_hex is not valid hex") from error
        if not isinstance(libfuzzer_seed, int) or not 1 <= libfuzzer_seed <= 2_147_483_647:
            raise TestFailure(f"{name}: libfuzzer_seed must be a positive 32-bit integer")
        expected_failure = target.get("expected_failure", False)
        if not isinstance(expected_failure, bool):
            raise TestFailure(f"{name}: expected_failure must be a boolean")

        skip = target.get("skip", {})
        if not isinstance(skip, dict) or set(skip) - set(STAGES):
            raise TestFailure(f"{name}: skip keys must be test stages")
        for stage, explanation in skip.items():
            if not isinstance(explanation, dict) or set(explanation) != {
                "reason",
                "issue",
            }:
                raise TestFailure(
                    f"{name}: skipped {stage} must have exactly reason and issue"
                )
            reason = explanation["reason"]
            issue = explanation["issue"]
            if not isinstance(reason, str) or not reason.strip():
                raise TestFailure(f"{name}: skipped {stage} needs a reason")
            if not isinstance(issue, str) or not GITHUB_ISSUE.fullmatch(issue):
                raise TestFailure(
                    f"{name}: skipped {stage} needs a full GitHub issue URL"
                )
        if "build" in skip and not {"seed", "fuzz"} <= set(skip):
            raise TestFailure(f"{name}: skipping build also requires skipping seed and fuzz")
        if "seed" in skip and "fuzz" not in skip:
            raise TestFailure(f"{name}: skipping seed also requires skipping fuzz")

    names = [str(target["name"]) for target in targets]
    if len(names) != len(set(names)):
        raise TestFailure("test_spec.json contains duplicate target names")

    retired = document["retired"]
    if not isinstance(retired, list) or not all(
        isinstance(target, dict)
        and set(target) == {"name", "reason"}
        and isinstance(target["name"], str)
        and isinstance(target["reason"], str)
        and target["name"]
        and target["reason"]
        for target in retired
    ):
        raise TestFailure("retired targets need non-empty name and reason strings")
    retired_names = [str(target["name"]) for target in retired]
    if len(retired_names) != len(set(retired_names)) or set(retired_names) & set(names):
        raise TestFailure("active and retired target names must be unique")

    actual: set[str] = set()
    directories = {path.parent for path in (ROOT / "examples").rglob("*.roc")}
    for directory in directories:
        roc_sources = sorted(directory.glob("*.roc"))
        main = directory / "main.roc"
        relative = directory.relative_to(ROOT).as_posix()
        if len(roc_sources) > 1 and relative not in SINGLE_FILE_COLLECTIONS:
            if main not in roc_sources:
                raise TestFailure(
                    f"multi-file example {relative} must have main.roc as its app root"
                )
            actual.add(main.relative_to(ROOT).as_posix())
        else:
            actual.update(path.relative_to(ROOT).as_posix() for path in roc_sources)
    declared = {str(target["path"]) for target in targets}
    if actual != declared:
        missing = sorted(actual - declared)
        stale = sorted(declared - actual)
        raise TestFailure(f"target inventory mismatch; missing={missing}, stale={stale}")

    if not selected:
        return targets
    unknown = sorted(set(selected) - set(names))
    if unknown:
        raise TestFailure(f"unknown targets: {', '.join(unknown)}")
    wanted = set(selected)
    return [target for target in targets if target["name"] in wanted]


def targets_for_stage(
    targets: list[dict[str, object]], stage: str
) -> list[dict[str, object]]:
    active: list[dict[str, object]] = []
    for target in targets:
        skip = target.get("skip", {})
        assert isinstance(skip, dict)
        if stage in skip:
            explanation = skip[stage]
            assert isinstance(explanation, dict)
            print(
                f"SKIP {stage} {target['name']}: "
                f"{explanation['reason']} ({explanation['issue']})"
            )
        else:
            active.append(target)
    return active


def roc_files() -> list[Path]:
    return sorted(
        [
            *(ROOT / "examples").rglob("*.roc"),
            *(ROOT / "platform").glob("*.roc"),
        ]
    )


# Targets exempt from the allocation-assertion norm, each with a concrete
# reason. Keep this list short: a target that measures nothing about cost
# cannot catch an allocation regression, which is a whole class of bug that
# produces correct answers and so is invisible to a content property.
ALLOCATION_ASSERTION_EXEMPT = {
    "failureArtifact": "fixture whose whole purpose is to fail on a known input",
}

ALLOCATION_ASSERTION = re.compile(
    r"\bFuzz\.expect_allocs_at_(?:most|least)!\s*\("
)


def strip_roc_comments_and_strings(source: str) -> str:
    """Remove text that must not satisfy source-level policy checks."""

    output: list[str] = []
    in_string = False
    escaped = False
    for line in source.splitlines():
        cleaned: list[str] = []
        for character in line:
            if in_string:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    in_string = False
                cleaned.append(" ")
            elif character == '"':
                in_string = True
                cleaned.append(" ")
            elif character == "#":
                break
            else:
                cleaned.append(character)
        output.append("".join(cleaned))
    return "\n".join(output)


def has_allocation_assertion(source: str) -> bool:
    return ALLOCATION_ASSERTION.search(strip_roc_comments_and_strings(source)) is not None


def check_allocation_policy_parser() -> None:
    accepted = "value = Fuzz.expect_allocs_at_most!(0, |{}| operation())"
    rejected = (
        "# Fuzz.expect_allocs_at_most!(0, |{}| operation())",
        'text = "Fuzz.expect_allocs_at_least!(1, |{}| operation())"',
        "measured = Fuzz.measure_allocs!(|{}| operation())",
        "Fuzz.expect_no_leaks!(|{}| operation())",
    )
    if not has_allocation_assertion(accepted) or any(
        has_allocation_assertion(source) for source in rejected
    ):
        raise TestFailure("allocation-assertion source policy parser is inconsistent")


def check_tracked_artifacts() -> None:
    """Keep generated executables and native inputs out of source control."""

    if not (ROOT / ".git").exists():
        return
    tracked = subprocess.check_output(
        ["git", "ls-files", "-z"], cwd=ROOT
    ).decode().split("\0")
    forbidden = [
        path
        for path in tracked
        if path == "examples/stack/main"
        or (
            path.startswith("platform/targets/")
            and (path.endswith((".a", ".o")) or path.endswith("/SHA256SUMS"))
        )
    ]
    if forbidden:
        raise TestFailure(
            "generated native artifacts must not be tracked:\n  "
            + "\n  ".join(sorted(forbidden))
        )


def check_allocation_assertions(targets: list[dict[str, object]]) -> None:
    """Every target should assert on allocation behaviour, not only on results."""

    missing: list[str] = []
    for target in targets:
        name = str(target["name"])
        if name in ALLOCATION_ASSERTION_EXEMPT:
            continue
        source = (ROOT / str(target["path"])).read_text(encoding="utf-8")
        if not has_allocation_assertion(source):
            missing.append(f"{name} ({target['path']})")
    if missing:
        listed = "\n  ".join(missing)
        raise SystemExit(
            "these targets assert nothing about allocations:\n  "
            + listed
            + "\n\nUse Fuzz.expect_allocs_at_most! or Fuzz.expect_allocs_at_least!"
            + " to pin the cost of the operation under test, or add the target to"
            + " ALLOCATION_ASSERTION_EXEMPT in scripts/test.py with a concrete reason."
        )


def target_path(target: dict[str, object], example_root: Path | None) -> Path:
    relative = Path(str(target["path"]))
    if example_root is None:
        return ROOT / relative
    return example_root / relative.relative_to("examples")


@contextmanager
def rewritten_examples(platform_url: str | None):
    if platform_url is None:
        yield None
        return
    CACHE.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="examples-", dir=CACHE) as temp:
        example_root = Path(temp) / "examples"
        shutil.copytree(ROOT / "examples", example_root)
        rewritten_count = 0
        for source in example_root.rglob("*.roc"):
            text = source.read_text(encoding="utf-8")
            rewritten, count = PLATFORM_DECLARATION.subn(
                f'platform "{platform_url}"', text, count=1
            )
            if count:
                source.write_text(rewritten, encoding="utf-8")
                rewritten_count += 1
        if rewritten_count == 0:
            raise TestFailure("no example platform declarations were rewritten")
        yield example_root


def check_targets(roc: str, targets: list[dict[str, object]], verbose: bool, example_root: Path | None) -> None:
    check_tracked_artifacts()
    check_allocation_policy_parser()
    run([roc, "fmt", "--check", *map(str, roc_files())], verbose=verbose)
    for target in targets:
        run([roc, "check", str(target_path(target, example_root))], verbose=verbose)
    check_allocation_assertions(targets)


def test_targets(roc: str, targets: list[dict[str, object]], verbose: bool, example_root: Path | None) -> None:
    for target in targets:
        run([roc, "test", str(target_path(target, example_root))], verbose=verbose)


def build_target(roc: str, target: dict[str, object], verbose: bool, example_root: Path | None) -> Path:
    output_dir = CACHE / "executables"
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / str(target["name"])
    run(
        [
            roc,
            "build",
            "--fuzz",
            str(target_path(target, example_root)),
            f"--output={output}",
        ],
        verbose=verbose,
    )
    validate_executable(output)
    return output


def validate_executable(output: Path) -> None:
    description = subprocess.check_output(["file", str(output)], text=True).strip()
    system = platform.system()
    if system == "Linux":
        if output.read_bytes()[:4] != b"\x7fELF":
            raise TestFailure(f"{output} is not an ELF executable")
        if "statically linked" not in description or "x86-64" not in description:
            raise TestFailure(f"unexpected executable format: {description}")
        return
    if system == "Darwin":
        if output.read_bytes()[:4] != b"\xcf\xfa\xed\xfe":
            raise TestFailure(f"{output} is not a 64-bit Mach-O executable")
        if "Mach-O 64-bit executable arm64" not in description:
            raise TestFailure(f"unexpected executable format: {description}")
        validate_macos_deployment_target(output)
        dependencies = subprocess.check_output(["otool", "-L", str(output)], text=True).splitlines()[1:]
        non_system = [line.strip().split(" ", 1)[0] for line in dependencies if line.strip() and not line.lstrip().startswith(("/usr/lib/", "/System/Library/"))]
        if non_system:
            raise TestFailure(
                f"{output} has non-system dynamic dependencies: {', '.join(non_system)}"
            )
        return
    raise TestFailure(f"unsupported host platform for executable validation: {system}")


def validate_macos_deployment_target(output: Path) -> None:
    lines = subprocess.check_output(["otool", "-l", str(output)], text=True).splitlines()
    for start, line in enumerate(lines):
        if line.strip() != "cmd LC_BUILD_VERSION":
            continue
        for candidate in lines[start + 1 : start + 8]:
            match = re.fullmatch(r"\s*minos (\d+)\.(\d+)(?:\.\d+)?\s*", candidate)
            if match is None:
                continue
            minimum = (int(match.group(1)), int(match.group(2)))
            if minimum != (11, 0):
                raise TestFailure(
                    f"unexpected macOS deployment target for {output}: "
                    f"{match.group(1)}.{match.group(2)} (expected 11.0)"
                )
            return
        raise TestFailure(f"LC_BUILD_VERSION has no parseable minimum target in {output}")
    raise TestFailure(f"{output} is missing LC_BUILD_VERSION")


def build_targets(
    roc: str, targets: list[dict[str, object]], verbose: bool, example_root: Path | None
) -> dict[str, Path]:
    if not targets:
        return {}
    system = platform.system()
    if system == "Linux":
        target_names = {"x64musl"}
    elif system == "Darwin":
        target_names = {"arm64mac"}
    else:
        raise TestFailure(f"unsupported host platform for target builds: {system}")
    if example_root is None:
        try:
            validate_platform_inputs(ROOT, target_names)
        except RuntimeError as error:
            raise TestFailure(str(error)) from error
    return {
        str(target["name"]): build_target(roc, target, verbose, example_root) for target in targets
    }


def seed_path(target: dict[str, object]) -> Path:
    corpus = CACHE / "corpus" / str(target["name"])
    corpus.mkdir(parents=True, exist_ok=True)
    path = corpus / "seed"
    path.write_bytes(bytes.fromhex(str(target["seed_hex"])))
    return path


def replay_seeds(
    executables: dict[str, Path],
    targets: list[dict[str, object]],
    verbose: bool,
) -> None:
    for target in targets:
        executable = executables[str(target["name"])]
        seed = seed_path(target)
        run([str(executable), "show", str(seed)], verbose=verbose, capture=not verbose)
        replay = [str(executable), "replay", str(seed)]
        if target.get("expected_failure", False):
            CACHE.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix="replay-", dir=CACHE) as temp:
                if verbose:
                    print("+", " ".join(replay), "# expected failure", flush=True)
                completed = subprocess.run(
                    replay,
                    cwd=temp,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                )
            if completed.returncode != 77:
                raise TestFailure(
                    f"expected replay failure from {target['name']}, got "
                    f"{completed.returncode}\n{completed.stdout}"
                )
        else:
            run(replay, verbose=verbose, capture=not verbose)


def fuzz_targets(
    executables: dict[str, Path],
    targets: list[dict[str, object]],
    seconds: int,
    verbose: bool,
) -> None:
    for target in targets:
        executable = executables[str(target["name"])]
        if target.get("expected_failure", False):
            verify_failure_artifact(executable, target, verbose)
            continue
        seed = seed_path(target)
        corpus = seed.parent
        CACHE.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="ci-report-", dir=CACHE) as temp:
            report_dir = Path(temp) / "evidence with spaces"
            run(
                [
                    str(executable),
                    "ci",
                    str(report_dir),
                    str(corpus),
                    f"--time={seconds}",
                    "--max-input-size=4096",
                    f"--seed={target['libfuzzer_seed']}",
                    "--source-revision=test-revision",
                    "--roc-version=test-roc",
                    "--platform-release=test-platform",
                    f"--platform-sha256={'a' * 64}",
                ],
                verbose=verbose,
                capture=not verbose,
            )
            verify_ci_evidence(
                report_dir,
                executable,
                target_name=None,
                expected_outcome="passed",
                expected_finding=None,
            )
    first_normal = next(
        (target for target in targets if not target.get("expected_failure", False)),
        None,
    )
    if first_normal is not None:
        verify_ci_argument_validation(
            executables[str(first_normal["name"])],
        )


def expect_exit_two(command: list[str], *, cwd: Path = ROOT) -> str:
    completed = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if completed.returncode != 2:
        raise TestFailure(
            f"expected command to exit 2, got {completed.returncode}: "
            f"{' '.join(command)}\n{completed.stdout}"
        )
    return completed.stdout


def verify_ci_argument_validation(executable: Path) -> None:
    CACHE.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ci-validation-", dir=CACHE) as temp:
        work = Path(temp)
        corpus = work / "missing corpus"
        report = work / "evidence with spaces"
        common = [
            "--source-revision=test-revision",
            "--roc-version=test-roc",
            "--platform-release=test-platform",
            f"--platform-sha256={'a' * 64}",
        ]
        run(
            [str(executable), "ci", str(report), str(corpus), "--runs=0", *common],
            capture=True,
        )
        verify_ci_evidence(
            report,
            executable,
            target_name=None,
            expected_outcome="passed",
            expected_finding=None,
        )
        if not corpus.is_dir():
            raise TestFailure("CI did not create a missing corpus directory")

        opt_out_report = work / "leak opt out"
        run(
            [
                str(executable),
                "ci",
                str(opt_out_report),
                str(corpus),
                "--runs=0",
                "--no-detect-leaks",
                *common,
            ],
            capture=True,
        )
        verify_ci_evidence(
            opt_out_report,
            executable,
            target_name=None,
            expected_outcome="passed",
            expected_finding=None,
            expected_leak_detection=False,
        )

        overlap_output = expect_exit_two(
            [str(executable), "ci", str(corpus), str(corpus), "--runs=0"]
        )
        if "must not overlap" not in overlap_output:
            raise TestFailure("CI did not explain overlapping report/corpus paths")

        occupied = work / "occupied"
        occupied.mkdir()
        sentinel = occupied / "keep"
        sentinel.write_text("preserve me", encoding="utf-8")
        expect_exit_two(
            [str(executable), "ci", str(occupied), str(corpus), "--runs=0"]
        )
        if sentinel.read_text(encoding="utf-8") != "preserve me":
            raise TestFailure("CI altered a non-empty report directory")

        malformed = work / "malformed-sha"
        sha_output = expect_exit_two(
            [
                str(executable),
                "ci",
                str(malformed),
                str(corpus),
                "--runs=0",
                "--platform-sha256=not-a-digest",
            ]
        )
        if "64 hexadecimal" not in sha_output:
            raise TestFailure("CI did not explain malformed platform SHA-256 metadata")

        unknown = work / "unknown-option"
        unknown_output = expect_exit_two(
            [str(executable), "ci", str(unknown), str(corpus), "--unknown-option"]
        )
        if "unknown option" not in unknown_output:
            raise TestFailure("CI did not explain an unknown option")


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(64 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_ci_evidence(
    report_dir: Path,
    executable: Path,
    *,
    target_name: str | None,
    expected_outcome: str,
    expected_finding: str | None,
    expected_leak_detection: bool = True,
) -> dict[str, object]:
    report_path = report_dir / "report.json"
    summary_path = report_dir / "summary.md"
    log_path = report_dir / "run.log"
    for required in (report_path, summary_path, log_path, report_dir / "failures"):
        if not required.exists():
            raise TestFailure(f"CI evidence is missing {required}")
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise TestFailure(f"invalid CI JSON report: {error}") from error

    required_keys = {
        "schema_version",
        "target",
        "started_at_unix_ms",
        "finished_at_unix_ms",
        "duration_ms",
        "outcome",
        "finding_kind",
        "provenance",
        "configuration",
        "executable",
        "termination",
        "libfuzzer",
        "corpus",
        "failures",
        "log",
    }
    if set(report) != required_keys:
        raise TestFailure(f"unexpected CI report keys: {sorted(set(report) ^ required_keys)}")
    if report["schema_version"] != "roc-fuzz-ci/v1":
        raise TestFailure("unexpected CI report schema version")
    if not isinstance(report["target"], str) or not report["target"]:
        raise TestFailure("CI report target must be a non-empty string")
    if target_name is not None and report["target"] != target_name:
        raise TestFailure(f"CI report target mismatch: {report['target']!r}")
    if report["outcome"] != expected_outcome or report["finding_kind"] != expected_finding:
        raise TestFailure(
            f"CI report result mismatch: {report['outcome']}/{report['finding_kind']}"
        )
    if not isinstance(report["duration_ms"], int) or report["duration_ms"] < 0:
        raise TestFailure("CI report duration must be a non-negative integer")
    if report["finished_at_unix_ms"] < report["started_at_unix_ms"]:
        raise TestFailure("CI report timestamps are reversed")
    provenance = report["provenance"]
    if provenance != {
        "source_revision": "test-revision",
        "roc_version": "test-roc",
        "platform_release": "test-platform",
        "platform_sha256": "a" * 64,
    }:
        raise TestFailure(f"CI report provenance mismatch: {provenance!r}")
    configuration = report["configuration"]
    if configuration["leak_detection"] is not expected_leak_detection:
        raise TestFailure("CI report leak-detection state mismatch")
    command_disabled_leaks = "--no-detect-leaks" in configuration["command"]
    if command_disabled_leaks is expected_leak_detection:
        raise TestFailure("CI report command disagrees with its leak-detection state")
    executable_report = report["executable"]
    if executable_report["sha256"] != sha256_path(executable):
        raise TestFailure("CI report executable digest mismatch")
    log_report = report["log"]
    if log_report["sha256"] != sha256_path(log_path) or log_report["size"] != log_path.stat().st_size:
        raise TestFailure("CI report log manifest mismatch")
    for collection_name in ("corpus", "failures"):
        collection = report[collection_name]
        paths = [entry["path"] for entry in collection]
        if paths != sorted(paths):
            raise TestFailure(f"{collection_name} manifest is not sorted")
        root = report_dir / "failures" if collection_name == "failures" else Path(configuration["corpus"])
        for entry in collection:
            path = root / entry["path"]
            if not path.is_file() or entry["size"] != path.stat().st_size or entry["sha256"] != sha256_path(path):
                raise TestFailure(f"invalid {collection_name} manifest entry: {entry!r}")
    summary = summary_path.read_text(encoding="utf-8")
    if expected_outcome not in summary or "not Roc statement or branch coverage" not in summary:
        raise TestFailure("CI Markdown summary is incomplete")
    return report


def verify_failure_artifact(
    executable: Path, target: dict[str, object], verbose: bool
) -> None:
    CACHE.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="failure-", dir=CACHE) as temp:
        work = Path(temp)
        corpus = work / "corpus"
        corpus.mkdir()
        seed = corpus / "reproducer"
        seed.write_bytes(bytes.fromhex(str(target["seed_hex"])))
        report_dir = work / "evidence"
        artifact = report_dir / "failures" / (
            "crash-" + hashlib.sha1(seed.read_bytes()).hexdigest()
        )

        completed = subprocess.run(
            [
                str(executable),
                "ci",
                str(report_dir),
                str(corpus),
                "--runs=10",
                "--source-revision=test-revision",
                "--roc-version=test-roc",
                "--platform-release=test-platform",
                f"--platform-sha256={'a' * 64}",
            ],
            cwd=work,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        if completed.returncode != 77:
            raise TestFailure(
                f"failure target exited with {completed.returncode}\n{completed.stdout}"
            )
        if not artifact.is_file() or artifact.read_bytes() != seed.read_bytes():
            raise TestFailure("libFuzzer did not save the exact reproducing input")
        report = verify_ci_evidence(
            report_dir,
            executable,
            target_name="crashing-target",
            expected_outcome="finding",
            expected_finding="roc_crash",
        )
        if report["termination"]["exit_code"] != 77:
            raise TestFailure("CI report did not preserve the Roc failure exit code")
        for command in (" show ", " replay ", " minimize "):
            if command not in completed.stdout:
                raise TestFailure(
                    f"failure output did not suggest {command.strip()}"
                )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--operation", choices=OPERATIONS, default="all")
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--max-total-time", type=int, default=2)
    parser.add_argument("--verbose", "-v", action="store_true")
    parser.add_argument(
        "--platform-url",
        help="test temporary example copies rewritten to this platform package URL",
    )
    args = parser.parse_args()

    if args.max_total_time < 1:
        raise SystemExit("--max-total-time must be at least one second")

    roc = os.environ.get("ROC", "roc")
    try:
        targets = load_targets(args.target)
        with rewritten_examples(args.platform_url) as example_root:
            if args.operation in ("all", "validate", "check"):
                check_targets(roc, targets_for_stage(targets, "check"), args.verbose, example_root)
            if args.operation in ("all", "validate", "test"):
                test_targets(roc, targets_for_stage(targets, "test"), args.verbose, example_root)

            if args.operation == "all":
                buildable = targets_for_stage(targets, "build")
                executables = build_targets(roc, buildable, args.verbose, example_root)
                replay_seeds(
                    executables,
                    targets_for_stage(targets, "seed"),
                    args.verbose,
                )
                fuzz_targets(
                    executables,
                    targets_for_stage(targets, "fuzz"),
                    args.max_total_time,
                    args.verbose,
                )
            elif args.operation in ("build", "seed", "fuzz"):
                stage_targets = targets_for_stage(targets, args.operation)
                executables = build_targets(roc, stage_targets, args.verbose, example_root)
                if args.operation in ("seed", "fuzz"):
                    replay_seeds(executables, stage_targets, args.verbose)
                if args.operation == "fuzz":
                    fuzz_targets(
                        executables,
                        stage_targets,
                        args.max_total_time,
                        args.verbose,
                    )
    except (OSError, subprocess.CalledProcessError, TestFailure) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
