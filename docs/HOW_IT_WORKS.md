# How it works

Internals of `what-changed`: what runs when, what state is kept, and how one invocation becomes a report. For the config file's syntax and the everyday commands, see the [README](../README.md).

## High-level flow

```
    what-changed <subcommand>
              │
              ▼
      read the config
              │
              ▼
      list the files git knows about
              │
              ▼
      hash every one of them
              │
              ▼
      compare those hashes against the baseline
              │
              ▼
      sort the differences into the targets that watch them
              │
              ▼
      report: "summary", "changes" or "targets"
```

Each stage has its own section below.

Recording is a separate command and never a side effect of reporting:

```
    what-changed baseline capture [names]  ──►  record what those targets watch (all of them with no names)
    what-changed baseline reset    ──►  write an empty baseline
    what-changed cache capture     ──►  hash the tree, write the file hash cache only
    what-changed cache reset       ──►  write an empty file hash cache
```

The file hash cache records each file's mtime, size and hash from the last run. When both the mtime and the size still match, the recorded hash is reused and the file is never opened. It only affects how long a run takes, never what gets reported, which is why it is kept apart from the baseline.

## The config file

Two formats are accepted, and the parser is chosen by the file's extension: `.yaml` or `.yml`, and `.json`. JSON goes through the standard library's parser. YAML goes through `src/lib/yaml.zig`, a bounded implementation of the subset the config format uses, because Zig's standard library has no YAML and the alternative was a package dependency. It supports block mappings, block sequences, one-line flow collections, comments and quoted scalars, and refuses anything else with a syntax error rather than misreading it. A syntax error names the format the file was read as, so a YAML mistake never reports itself as a JSON one.

An unrecognised extension is an error rather than a guess. Reading a YAML file as JSON would fail with a message about the wrong thing entirely.

With no `--config` given, `findConfig` tries `what-changed.yaml`, `what-changed.yml` and `what-changed.json` in that order and uses the first it finds. Finding none names all three, because "no config found" without the list leaves the user guessing which spellings are allowed.

Validation is deliberately unforgiving: a malformed config is a hard error naming the offending field and value. A config that quietly half-applied would mean a target that quietly stopped being watched, which is silent and permanent. Note the contrast with the cache, below, where the opposite rule applies.

## The file list

Enumeration goes through `git ls-files -z --cached --others --exclude-standard`, run in `rootDir`. That is tracked files plus untracked files that no ignore rule matches.

Using git rather than a directory walk buys exact `.gitignore` semantics for free, including nested `.gitignore` files, negations, and the global excludes file. Writing an equivalent matcher would be more code and would drift from what git actually ignores.

The cost is a hard requirement: the project must be a git repository and `git` must be on `PATH`. When it is not, the run fails loudly rather than falling back to a directory walk, because a silently smaller file list means a silently missed change.

The `-z` form is what makes paths with spaces, quotes or newlines survive intact. `parseGitFileList` splits on NUL only, then sorts and de-duplicates.

`ignore` is applied to that list before anything else happens. Filtering at enumeration rather than at report time is what makes the rule total: an ignored file cannot reach the diff, so it cannot appear under any target and cannot appear in the changed-file listing either. The recorded baseline is filtered by the same rule when it is read back, so adding an extension to the list does not report every already-recorded file of that type as a deletion.

`git ls-files` returns paths relative to the directory it runs in, so everything downstream is relative to `rootDir`, which is the config file's directory. Put the config at the repository root unless you deliberately want only a subtree watched.

Both the cache directory and the baseline directory must be gitignored. The tool lists untracked files, so an un-ignored cache or baseline would show up as a change to itself on every single run.

## Hashing

`hashFile` stats the file first. If `file-hashes.json` holds an entry whose `mtime_ms` and `size` both match, the recorded hash is returned and the file is never opened. Otherwise the file is read and a SHA-256 hex digest is computed and written back into the cache.

Both fields have to match. Size alone misses a same-length edit; mtime alone misses a filesystem with coarse timestamps and misses a restore that resets the timestamp.

A file that has vanished between being listed and being hashed returns the literal `<missing>` rather than an error, and its cache entry is left alone. The listing and the hashing are two separate passes over a live working tree, so this race is normal. `presentFiles` then drops those entries before the diff, so a file git still lists after deletion is reported as deleted rather than as modified to the literal text `<missing>`.

Hashing is sequential. In the steady state it is one `stat` per file and nothing else, so there is no throughput to win and no file-descriptor ceiling to reason about. See [performance.md](performance.md) for what it costs.

`pruneFileHashes` drops entries for files that are no longer in the list, so a long-lived checkout does not accumulate an entry for every file it has ever had.

## The diff

`diffFileHashes` compares a set of freshly computed hashes against a recorded set and returns one `ChangedFile` per difference, sorted by path. A path present now but not in the baseline is `added`; present in both with different hashes is `modified`; in the baseline but not present now is `deleted`. A deleted file carries the hash it used to have, since there is no current one.

It is pure, so the whole comparison is testable without touching a disk.

The comparison is against recorded hashes, not against a commit, so it answers a different question from `git status` and will disagree with it. Checking out a branch or pulling changes the file hashes, and the targets watching those files are reported even though the tree is clean as far as git is concerned.

## Categorising

`categorizeChanges` works out, for every target, which of the files it watches differ from that target's own record. A target's watched paths are its own `paths` merged with the config's `always`, de-duplicated and sorted, and `filesUnderWatchedPaths` narrows the tree to those before the diff runs.

A file falls under a watched path when it *is* that path or sits below it. The separator check in `isUnderWatchedPath` is what stops `src` matching `srcircus/a.ts`: without it, any path merely starting with the same letters would count, and a target would report changes it does not watch.

Two consequences, both deliberate:

- **A file can land under several targets.** A change under `src` belongs to every target watching `src`. Nothing picks a winner.
- **A file can land under none**, and those are collected in `unwatchedFiles` rather than dropped. A changed file that nothing watches is usually a gap in the config, and staying silent about it would hide exactly the case worth knowing.

## Platform filtering

`categorizeChanges` takes the host platform, and `targetAppliesToPlatform` decides whether each target can run on it. An empty `platforms` list means every platform. A non-empty one is exclusive.

A target that does not apply gets `applies_here: false` and an empty `changed_files`, whatever fell under its paths. A target that cannot run is not affected by anything, so there is nothing for a caller to act on.

Three things follow, and each is a decision rather than a side effect:

- **`unwatchedFiles` is decided by watched paths, not by whether the target applies.** A file watched only by an excluded target is still watched. Calling it unwatched would send someone looking for a gap in the config that is not there.
- **`summary` prints `wrong-platform` rather than `unchanged`.** "Unchanged" would be a lie about a target that could not have run whatever changed, and dropping the line would look like a misspelled target name.
- **`targets` never names an excluded target.** A target that cannot run here has no changed files, so it cannot reach the list of affected names.
- **`targets list` answers what could run rather than what needs to.** It reads the config, filters by platform, and stops: no file listing, no hashing, no baseline. That is what a calling script's "run everything" path asks, and taking the list from here rather than hardcoding one keeps the platform check on that path.

The platform is a parameter of `report` rather than a read of the host's platform name inside the flow, for the same reason the working directory and the file lister are: the whole thing can then be driven for any platform from a test, without the test only ever exercising the machine it happens to run on.

## Output formats

`--output` takes `text`, `json` or `yaml`, defaulting to `text`.

The three are not three code paths. `report` builds one `ReportResult` and hands it to `renderReport`, which either prints the human text or passes `structuredReport`'s object to `printStructured`. The text a person reads and the JSON a script reads are therefore built from the same object and cannot disagree about what changed.

`structuredReport` renders only what the chosen view is about: `targets` gives a list of names, not a whole report with the names buried in it. JSON and YAML render the identical object, so switching between them changes only the punctuation.

An unrecognised format is rejected, naming every accepted one. Quietly defaulting to text would produce output that whatever downstream parser was asked for cannot read, and the mistake would surface as a parse error somewhere else entirely.

## The baseline and the cache

Two separate stores, both under `.what-changed/` so a project has a single path to gitignore.

| | Baseline (`lib/baseline_store.zig`) | File hash cache (`lib/cache_store.zig`) |
| --- | --- | --- |
| Default location | `.what-changed/baseline.json` | `.what-changed/cache/file-hashes.json` |
| Holds | Per target, the hashes of the files that target watched when it was captured | Path to mtime, size and content hash |
| Written by | `baseline capture`, `baseline reset` | every report, and `cache capture`/`cache reset` |
| Losing it | **Changes the answer.** Everything reads as new | Costs one slow run and nothing else |

The cache sits in its own subdirectory rather than beside the baseline, so `cache reset` cannot reach the baseline and `baseline reset` cannot reach the cache. Deleting `.what-changed/` by hand takes both, which costs a full report rather than a wrong one.

### Why the baseline is per target

Targets pass at different moments. A single tree-wide snapshot can only honestly be written when everything has passed together, because writing it after one suite would mark every other suite as up to date without them having run. That failure is silent and it lets a broken commit through, which makes it the worst one this tool can have.

So `baseline.json` holds one record per target:

```json
{
  "targets": {
    "compile": { "src/a.ts": "hash", "package.json": "hash" },
    "test:cli": { "apps/cli/index.ts": "hash", "package.json": "hash" }
  },
  "files": { "...": "..." }
}
```

Each target records only the files it watches, which is its own `paths` merged with `always`. `categorizeChanges` compares each target against its own record, so a target absent from `targets` has never been captured and everything it watches counts as changed. `withCapturedTargets` replaces only the named entries and leaves every other record untouched, which is what makes `baseline capture test:cli` safe to run after the CLI suite alone.

`files` is the whole tree at the most recent capture of any kind, and is used for one thing only: deciding whether a file that **no** target watches has changed. Such a file has no target record to compare against, and dropping it entirely would hide the config gap it represents.

A baseline written by an older version was a flat path-to-hash map. `loadBaseline` reads that as no baseline at all, so the first run after an upgrade does the work rather than skipping it.

Both resets write an empty object rather than deleting a file. Everything that reads them treats empty and absent identically, and a write cannot go wrong the way a delete of a computed path can: if the path were ever empty or wrong, a delete would take something real with it.

Both files are written to a `.tmp` sibling and renamed over the target, so a crash part way through a write cannot leave a half-written file for the next run to choke on.

## Reading state back

`loadCache` and `loadBaseline` are deliberate about being unable to fail. A missing directory, a missing file, JSON that will not parse, or JSON that parses to an array, a number or `null` all produce an empty object.

The reasoning is asymmetric. A damaged baseline that reads as empty reports everything as new: noisy, correct, self-healing. A damaged baseline that raised would block a report for a reason the user cannot act on. The first failure mode is strictly better, so it is the one that was chosen.

## Recording is never a side effect

Reporting writes no baseline. Looking twice reports the same thing twice, and looking is always free.

That matters most in a script. Because the capture is a separate command the caller controls, it can be chained after the suite with `&&` and reached only when that suite passed. A tool that moved the baseline as it reported would mark a broken tree as good.

Per-target capture is what makes that safe to put inside each suite's own command rather than at the end of a whole run:

```bash
zig build test  && what-changed baseline capture test
./cli-tests.sh && what-changed baseline capture test:cli
```

Each one then marks only itself, however it was started, and a run of just one suite leaves the others correctly reported as still needing to run.

The file hash cache is different, and is written on every report. It records only what a file's content hashes to, which is true regardless of whether anything passed.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | It ran and reported, whether or not anything changed |
| 1 | The tool itself failed: unreadable or invalid config, unrecognised config extension, unknown option, git missing or failing |

"Something changed" is not an error. A script asks `what-changed targets` and checks whether the output is empty.

## What it cannot see

The tool only knows about the working tree. Anything outside it is invisible:

- A different emulator, a new SDK version, a changed environment variable, a rotated credential.
- A dependency installed into a package directory, which is usually gitignored and therefore never hashed. Put the lockfile in `always` for exactly this reason: it is the tracked proxy for the installed tree.
- Time. There is no cooldown and no expiry. A tree identical to the baseline reads as unchanged however long ago that baseline was captured.

## Module map

| File | Holds |
| --- | --- |
| `build.zig` | The build: the CLI, the unit tests, the release binary and the benchmarks. |
| `src/main.zig` | The entry point: the wiring from the real process to the flows. Nothing may import it. |
| `src/cmd/summary.zig` | The `summary` command. |
| `src/cmd/changes.zig` | The `changes` command. |
| `src/cmd/targets.zig` | The `targets` command and its `list` subcommand. |
| `src/cmd/baseline.zig` | The `baseline` command: `capture`, `reset`, `show`. |
| `src/cmd/cache.zig` | The `cache` command: `capture`, `reset`, `show`. |
| `src/cmd/version.zig` | The `version` command. |
| `src/cmd/harness.zig` | The throwaway project the command tests are driven against. |
| `src/lib/lib.zig` | Re-exports every library module under one name, so the CLI and the benchmarks share one import. |
| `src/lib/commander.zig` | The command line library: the parts of `commander` this tool uses. |
| `src/lib/run.zig` | `report`, `runBaseline`, `runCacheCapture` and `listTargets`: the whole flow. Take the working directory, the file lister, the platform and the output as arguments, so they can be driven against a throwaway directory. |
| `src/lib/config.zig` | Finding, parsing and validating the config, in both formats. |
| `src/lib/list_files.zig` | The git enumeration, its NUL parser, and the `FileLister` type. |
| `src/lib/file_hash.zig` | Per-file hashing and the mtime/size cache. |
| `src/lib/file_hashes.zig` | The path-to-hash map the reports and the stores are built on. |
| `src/lib/changed_files.zig` | The diff against the baseline and its formatting. |
| `src/lib/categorize.zig` | Sorting changed files into the targets that watch them. |
| `src/lib/output.zig` | The output formats, the JSON/YAML rendering, and `Output`, which every command prints through. |
| `src/lib/cache_store.zig` | Reading and writing the file hash cache, and the cross-process update lock. |
| `src/lib/baseline_store.zig` | Reading and writing the baseline. |
| `src/lib/files.zig` | The filesystem operations everything else is built out of, and the throwaway directory tests use. |
| `src/lib/json.zig` | Reading and writing JSON. |
| `src/lib/yaml.zig` | Reading and writing YAML. |
| `src/lib/value.zig` | The dynamic value a parsed config and a rendered report are held in. |
| `src/lib/failure.zig` | Carrying the message that goes with a failure. |
| `src/lib/version.zig` | The version string and build metadata. Overwritten by a release build; reads `dev` in a working copy. |

## Design notes

Five decisions that shape the code and are not obvious from reading any single file.

**Errors carry their message beside them, not inside them.** Zig errors are bare enum values and cannot hold a string. Every fallible function therefore takes a `*Failure`, writes its message into it, and returns `error.Failed`. The top of the CLI prints whatever is in there. Nothing branches on which failure happened: every one of them ends the same way, printed to stderr with exit code 1, so what is modelled is the part that matters, which is that the wording reaches the user.

**One arena allocates the whole run.** Every allocation this tool makes is needed until the run ends and none of it is needed after, which is exactly the case an arena is for. No function has to think about freeing, and no failure path can leak, because there is one thing to release and `main` releases it.

**The output goes through a writer that is passed in.** The reporting functions take an `Output`, which is a buffered file writer in the CLI and a growing buffer in a test. That is what lets a test assert on a whole rendered report rather than on the pieces it is built from, and it is why `src/lib` never touches stdout itself.

**One map type serves both the live tree and the stored records.** `std.StringArrayHashMapUnmanaged` preserves insertion order the way a JSON object does, so the hashes just computed and the hashes read back off disk are the same type, and there is no conversion between them to get wrong.

**The command line is a library, not application code.** `src/lib/commander.zig` is a port of the parts of `commander` this tool uses, so the command definitions in `src/cmd` read as the same code as the TypeScript's. It generates the help from those definitions, which is why a `--help` from either port is byte for byte the same text.
