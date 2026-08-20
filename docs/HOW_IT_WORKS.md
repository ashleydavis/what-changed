# How it works

The ideas behind `what-changed`: what it considers a file, what it considers a change, and why the recorded state is arranged the way it is. For the config syntax and the everyday commands, see the [README](../README.md).

A **target** is a named job you would run, like `compile` or `test`. Each one lists paths in the config, and every file at or below one of those paths is one of that target's **watched** files. `what-changed` compares those files against what was recorded the last time that target passed, and prints the target's name if any of them differ, so a script can run the target.

## The flow

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

## What is recorded

Two files are recorded under `.what-changed/` for different jobs:

The **baseline**, at `.what-changed/baseline.json`, is the last recorded good point. It holds each target's watched files and their hashes, as they were when that target last passed. Every report is measured against it. Delete it and the next report says every file is new and every target needs to run.

The **file hash cache**, at `.what-changed/cache/file-hashes.json`, only makes things faster. It remembers each file's hash, and the modification time and size the file had when that hash was computed. On the next run, a file whose modification time and size both still match is answered straight from the cache. Delete the cache and the next run reads every file again.

You record the baseline yourself, by running `what-changed baseline capture <target>`.

The baseline holds one record per target rather than one snapshot of the whole tree. Targets pass one at a time, so a whole-tree snapshot written after one test suite passes would mark every other test suite as up to date too.

Examples of capturing the baseline for example targets `compile` and `test`:

```bash
zig build      && what-changed baseline capture compile
zig build test && what-changed baseline capture test
```

The cache sits in its own subdirectory, so `cache reset` touches only the cache and `baseline reset` touches only the baseline. Deleting `.what-changed/` by hand takes both, so the next run reports every file as new and every target runs.

## What counts as a file

`what-changed` gets the file list from git, by running `git ls-files -z --cached --others --exclude-standard`. So a new file counts the moment you save it.

`ignore` in the config lists file extensions to leave out, like `.md`. It is applied to the file list before anything else happens, so an ignored file is dropped before the comparison. The baseline gets the same filter when it is read back, so newly ignored files do not read as deletions.

Both the cache directory and the baseline directory must be gitignored. The tool lists untracked files, so an un-ignored cache or baseline would show up as a change to itself on every run.

## What counts as a change

A file is compared by the SHA-256 of its content. Files are read in chunks, so hashing a huge file never causes the process to run out of memory.

Each changed file has one of four kinds. This is the `kind` field in the JSON output, and the letter in front of each line in the text output:

| Kind | Meaning |
| --- | --- |
| `added` | In the tree, not in the baseline |
| `modified` | In both, with different hashes |
| `deleted` | In the baseline, not in the tree |
| `unreadable` | On disk, and something stopped it being read |

A deleted or unreadable file shows the last hash anyone managed to compute.

`unreadable` covers every reason a file could not be read due to problems: permissions, a symlink loop, an I/O error, no file descriptors left. It counts as changed, because there is no hash to compare against the baseline.

Checking out a branch or pulling commits causes file hashes to be updated, so any target whose paths cover those files is reported.

## Matching files to targets

A target covers its own paths and those in the config's `always`. Matching is on whole path segments, so `src` covers `src/a.ts` but not `src-generated/a.ts`.

Two consequences:

- **A file can be covered by several targets.** A change under `src` belongs to every target listing `src`.
- **A file can be covered by no target at all.** Those files get their own section in the report, since a changed file no target covers might be something missing in the config.

## Platform-specific targets

A target's `platforms` list names the operating systems it can run on, spelled `linux`, `darwin` or `win32`. Leave the list out and the target runs on all of them. `what-changed` compares the list against the machine it is running on.

A target that cannot run on this machine is **excluded**. Its changed-file list is always empty, however many files under its paths changed. Three things follow:

- **A file covered only by an excluded target is still covered.** On Linux, a change under an iOS-only target stays out of the "Watched by no target" section, because a target does cover it, just one that cannot run on this machine.
- **`summary` prints `wrong-platform` rather than `unchanged`**, since the target cannot run on this machine, changed or not.
- **`targets` prints only targets that can run on this machine**, because running an excluded target would fail.

`targets list` prints every target that can run on this machine, whether or not anything changed.

## What it cannot see

The tool only knows about the working tree. Anything outside it is invisible:

- A different emulator, a new SDK version, a changed environment variable, a rotated credential.
- A dependency installed into a package directory. If that directory is gitignored its contents stay out of the file list, so put the lockfile in `always`.
- Time. A baseline stays good until you capture a new one, so a tree identical to it reads as unchanged however long ago it was captured.
