# FallingNotes

## ALWAYS BUILD AFTERWARDS

After ANY code change, ALWAYS run `./build.sh` before finishing, so `FallingNotes.app` is rebuilt and up to date.
Plain `swift build` is not enough: it does not update the `.app` the user opens. Run `./build.sh` before committing
or pushing, and report whether it succeeded.
