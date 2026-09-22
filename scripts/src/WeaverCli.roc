import cli.OsStr
import cli.Stderr
import cli.Stdout
import weaver.Cli

## A common boundary between Weaver and repository scripts.
##
## `Run` carries validated options. `Exit` means Weaver already rendered help or
## version output, so callers can return successfully without inventing sentinel
## option values.
CliResult(options) : [Run(options), Exit]

WeaverCli := [].{
	parse! = |parser, raw_args|
		match Cli.parse_or_display_message(parser, raw_args.drop_first(1), OsStr.to_raw) {
			Ok(options) => Ok(Run(options))
			Err(Help(message)) | Err(Version(message)) => {
				Stdout.line!(message)?
				Ok(Exit)
			}
			Err(InvalidUsage(message)) => {
				Stderr.line!(message)?
				Err(InvalidCommandLine)
			}
		}
}
