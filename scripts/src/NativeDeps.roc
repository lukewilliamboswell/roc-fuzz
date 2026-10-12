import "../native-deps.json" as native_dependencies_json : Str
import Identity
import Version
LibfuzzerDependency : { sha256 : Str, url : Str, version : Str }

RawNativeDeps : {
	libfuzzer : LibfuzzerDependency,
	recipe_revision : U64,
	repository : Str,
	schema : U64,
	zig_version : Str,
}

NativeLibfuzzerDependency : { sha256 : Identity.Sha256, url : Str, version : Str }

## The validated recipe for the host and its linker inputs: the Zig release
## that builds them and the libFuzzer source they are built from. Everything
## else the repository pins lives in Blueprint.roc and Blueprint.lock.
NativeDeps := {
	libfuzzer : NativeLibfuzzerDependency,

	## Raised by hand when a change to the build recipe alters a library byte:
	## a flag, a target, the list of libraries. The producer rebuilds and
	## compares on every such pull request, and fails one that forgot.
	recipe_revision : U64,
	repository : Identity.Repository,
	schema : U64,
	zig_version : Str,
}.{

	## Native dependencies decoded and validated during compilation.
	current : NativeDeps
	current = NativeDeps.parse(native_dependencies_json).catch(
		|err| crash "invalid scripts/native-deps.json: ${Str.inspect(err)}",
		|value| value,
	)

	parse = |source| {
		decoded : RawNativeDeps
		decoded = Json.parse(source).map_err(|err| InvalidNativeDependenciesJson(err))?
		libfuzzer_sha256 = match Identity.Sha256.parse(decoded.libfuzzer.sha256) {
			Ok(value) => value
			Err(_) => return Err(InvalidLibfuzzerSha256)
		}
		repository = match Identity.Repository.parse(decoded.repository) {
			Ok(value) => value
			Err(_) => return Err(InvalidNativeRepository(decoded.repository))
		}
		NativeDeps.validate(
			NativeDeps.{
				libfuzzer: { sha256: libfuzzer_sha256, url: decoded.libfuzzer.url, version: decoded.libfuzzer.version },
				recipe_revision: decoded.recipe_revision,
				repository,
				schema: decoded.schema,
				zig_version: decoded.zig_version,
			},
		)
	}

	validate = |self| {
		if self.schema != 3 {
			return Err(UnsupportedNativeDependenciesSchema(self.schema))
		}
		if !Version.semantic(self.zig_version) {
			return Err(InvalidNativeZigVersion(self.zig_version))
		}
		if !Version.semantic(self.libfuzzer.version) {
			return Err(InvalidLibfuzzerVersion(self.libfuzzer.version))
		}
		if !starts_with(self.libfuzzer.url, "https://") {
			return Err(InvalidLibfuzzerUrl(self.libfuzzer.url))
		}
		Ok(self)
	}
}

starts_with = |value, prefix| value.to_utf8().take_first(prefix.to_utf8().len()) == prefix.to_utf8()
