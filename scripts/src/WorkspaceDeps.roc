import "../workspace-deps.json" as workspace_dependencies_json : Str
import Identity
import Version
PackageUrls : { ansi : Str, arg_path : Str, ascii : Str, basic_cli : Str, weaver : Str }

LibfuzzerDependency : { sha256 : Str, url : Str, version : Str }

RocAutomationDependency : { build_docs_revision : Str, repository : Str }

RawWorkspaceDeps : {
	libfuzzer : LibfuzzerDependency,
	package_urls : PackageUrls,
	repository : Str,
	roc_automation : RocAutomationDependency,
	roc_stable : Str,
	roc_nightly : Str,
	schema : U64,
	setup_roc_revision : Str,
	zig_version : Str,
}

WorkspaceLibfuzzerDependency : { sha256 : Identity.Sha256, url : Str, version : Str }

## Validated, repository-wide versions and immutable dependency identities.
## Roc app headers intentionally repeat their bootstrap package literals because
## those dependencies must resolve before this module can be loaded.
WorkspaceDeps := {
	libfuzzer : WorkspaceLibfuzzerDependency,
	package_urls : PackageUrls,
	repository : Identity.Repository,
	roc_automation : RocAutomationDependency,
	roc_stable : Str,
	roc_nightly : Str,
	schema : U64,
	setup_roc_revision : Identity.GitRevision,
	zig_version : Str,
}.{

	## Repository dependencies decoded and validated during compilation.
	current : WorkspaceDeps
	current = WorkspaceDeps.parse(workspace_dependencies_json).catch(
		|err| crash "invalid scripts/workspace-deps.json: ${Str.inspect(err)}",
		|value| value,
	)

	parse = |source| {
		decoded : RawWorkspaceDeps
		decoded = Json.parse(source).map_err(|err| InvalidWorkspaceDependenciesJson(err))?
		libfuzzer_sha256 = match Identity.Sha256.parse(decoded.libfuzzer.sha256) {
			Ok(value) => value
			Err(_) => return Err(InvalidLibfuzzerSha256)
		}
		repository = match Identity.Repository.parse(decoded.repository) {
			Ok(value) => value
			Err(_) => return Err(InvalidWorkspaceRepository(decoded.repository))
		}
		setup_revision = match Identity.GitRevision.parse(decoded.setup_roc_revision) {
			Ok(value) => value
			Err(_) => return Err(InvalidSetupRocRevision)
		}
		WorkspaceDeps.validate(
			WorkspaceDeps.{
				libfuzzer: { sha256: libfuzzer_sha256, url: decoded.libfuzzer.url, version: decoded.libfuzzer.version },
				package_urls: decoded.package_urls,
				repository,
				roc_automation: decoded.roc_automation,
				roc_stable: decoded.roc_stable,
				roc_nightly: decoded.roc_nightly,
				schema: decoded.schema,
				setup_roc_revision: setup_revision,
				zig_version: decoded.zig_version,
			},
		)
	}

	validate = |self| {
		if self.schema != 1 {
			return Err(UnsupportedWorkspaceDependenciesSchema(self.schema))
		}
		if !Version.nightly(self.roc_nightly) {
			return Err(InvalidWorkspaceRocNightly(self.roc_nightly))
		}
		if !Version.nightly(self.roc_stable) {
			return Err(InvalidWorkspaceRocStable(self.roc_stable))
		}
		if !Version.semantic(self.zig_version) {
			return Err(InvalidWorkspaceZigVersion(self.zig_version))
		}
		if !Version.semantic(self.libfuzzer.version) {
			return Err(InvalidLibfuzzerVersion(self.libfuzzer.version))
		}
		if !starts_with(self.libfuzzer.url, "https://") {
			return Err(InvalidLibfuzzerUrl(self.libfuzzer.url))
		}
		if !is_lower_hex(self.roc_automation.build_docs_revision, 40) {
			return Err(InvalidBuildDocsRevision)
		}
		if !starts_with(self.roc_automation.repository, "https://") or !ends_with(self.roc_automation.repository, ".git") {
			return Err(InvalidRocAutomationRepository(self.roc_automation.repository))
		}
		for (name, url) in [
			("basic_cli", self.package_urls.basic_cli),
			("ascii", self.package_urls.ascii),
			("ansi", self.package_urls.ansi),
			("arg_path", self.package_urls.arg_path),
			("weaver", self.package_urls.weaver),
		] {
			if !starts_with(url, "https://github.com/") or !ends_with(url, ".tar.zst") {
				return Err(InvalidWorkspacePackageUrl(name, url))
			}
		}
		Ok(self)
	}
}

is_lower_hex = |value, length| {
	bytes = value.to_utf8()
	bytes.len() == length and bytes.all(|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))
}

starts_with = |value, prefix| value.to_utf8().take_first(prefix.to_utf8().len()) == prefix.to_utf8()

ends_with = |value, suffix| {
	bytes = value.to_utf8()
	tail = suffix.to_utf8()
	bytes.len() >= tail.len() and bytes.drop_first(bytes.len() - tail.len()) == tail
}
