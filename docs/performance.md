# Performance

The whole point of this tool is to be so much cheaper than the tests it guards that nobody thinks about its cost. This documents what it actually costs and how that was measured.

It also compares the numbers against the TypeScript implementation this one replaced, at every stage and end to end. That comparison is kept because it is the evidence for the rewrite: it says what the change actually bought, in numbers, rather than leaving it to be assumed.

Run the benchmarks yourself with `zig build perf` from the package directory. They exit non-zero if any stage blows its budget, so they work as a regression test and not only as a report.

## Zig against TypeScript, end to end

This is the number that matters, because it is the one a build script pays every time it asks what changed. Measured on Linux, on a real git repository of 2002 files, driving each port's shipped executable as a real process. Ten runs per measurement, the median taken, and the whole thing repeated twice; where the two repeats disagreed, both medians are shown.

| | TypeScript (Bun 1.3.14) | Zig 0.16.0 (ReleaseFast) | Zig is |
| --- | --- | --- | --- |
| Runtime startup floor | 36ms | <1ms | ~36x cheaper |
| Cold check (every file read and hashed) | 80-82ms | 10ms | ~8x faster |
| Warm check (cache present, nothing changed) | 79-80ms | 12ms | ~6.6x faster |
| Summary report, warm, one file changed | 79-80ms | 12ms | ~6.6x faster |
| Baseline capture, warm | 81-82ms | 14ms | ~5.8x faster |
| Executable size | 90MB | 5.5MB | 16x smaller |

The TypeScript numbers moved by a millisecond or two between repeats and the Zig ones barely moved, which is what the ranges above are. Neither moved enough to change any ratio, so the multipliers are quoted as approximate rather than to a decimal place they have not earned.

The startup floor is the largest single difference and the easiest to explain: the TypeScript's ~80ms warm check is roughly 36ms of Bun starting up and loading modules before a line of this tool's own code runs, and the Zig binary's equivalent is under a millisecond. That is not something the TypeScript can optimise away from inside; it is the price of the runtime.

The startup floor itself was measured separately, by timing `bun <empty module>.ts` and `bun src/cli.ts --version` against the Zig binary's `--version`: an empty module costs Bun about 8ms and loading the real CLI about 36ms, against under a millisecond for the binary.

Take the startup out and the remaining work still favours Zig by roughly 4x, which is the stage-by-stage table below.

## Stage by stage

The benchmark harness measures the stages a check is made of, without process startup, at four tree sizes. Measured on Linux, files of 512 bytes spread 50 to a directory. Every number is a single measured run, so treat the small values as indicative rather than precise.

Zig:

| Stage | 100 files | 1000 files | 5000 files | 20000 files |
| --- | --- | --- | --- | --- |
| hash (cold, reads every file) | 0.3ms | 3.6ms | 14.4ms | 57.9ms |
| hash (warm, stat only) | 0.1ms | 0.7ms | 3.6ms | 16.1ms |
| build hash tree | 0.0ms | 0.3ms | 1.4ms | 8.6ms |
| lookup every watched path | 0.0ms | 0.0ms | 0.0ms | 0.0ms |
| diff files (nothing changed) | 0.0ms | 0.1ms | 0.7ms | 2.3ms |
| diff files (one changed) | 0.0ms | 0.1ms | 0.4ms | 2.4ms |

TypeScript, the same benchmark on the same machine:

| Stage | 100 files | 1000 files | 5000 files | 20000 files |
| --- | --- | --- | --- | --- |
| hash (cold, reads every file) | 2.4ms | 19.0ms | 96.8ms | 372.3ms |
| hash (warm, stat only) | 0.8ms | 7.6ms | 39.1ms | 157.1ms |
| build hash tree | 0.8ms | 1.6ms | 6.7ms | 26.8ms |
| lookup every watched path | 0.1ms | 0.0ms | 0.1ms | 0.2ms |
| diff files (nothing changed) | 0.1ms | 0.4ms | 2.1ms | 5.3ms |
| diff files (one changed) | 0.1ms | 0.3ms | 1.9ms | 5.8ms |

How many times faster Zig is, at 20000 files:

| Stage | TypeScript | Zig | Zig is |
| --- | --- | --- | --- |
| hash (cold, reads every file) | 372.3ms | 57.9ms | 6.4x faster |
| hash (warm, stat only) | 157.1ms | 16.1ms | 9.8x faster |
| build hash tree | 26.8ms | 8.6ms | 3.1x faster |
| diff files (nothing changed) | 5.3ms | 2.3ms | 2.3x faster |
| diff files (one changed) | 5.8ms | 2.4ms | 2.4x faster |

Per file, which is what shows whether a stage scales linearly. Zig:

| Stage | 100 files | 1000 files | 5000 files | 20000 files |
| --- | --- | --- | --- | --- |
| hash (cold) | 2.65us | 3.57us | 2.88us | 2.90us |
| hash (warm) | 0.51us | 0.67us | 0.73us | 0.80us |
| build hash tree | 0.37us | 0.31us | 0.28us | 0.43us |
| lookup every watched path | 0.00us | 0.00us | 0.00us | 0.00us |
| diff files (nothing changed) | 0.08us | 0.10us | 0.14us | 0.11us |
| diff files (one changed) | 0.07us | 0.09us | 0.09us | 0.12us |

TypeScript:

| Stage | 100 files | 1000 files | 5000 files | 20000 files |
| --- | --- | --- | --- | --- |
| hash (cold) | 24.25us | 19.05us | 19.36us | 18.61us |
| hash (warm) | 8.03us | 7.61us | 7.83us | 7.86us |
| build hash tree | 8.11us | 1.60us | 1.34us | 1.34us |
| lookup every watched path | 0.68us | 0.01us | 0.02us | 0.01us |
| diff files (nothing changed) | 1.07us | 0.38us | 0.42us | 0.26us |
| diff files (one changed) | 1.07us | 0.26us | 0.39us | 0.29us |

Both ports are linear in the file count at every stage. Nothing in either degrades as a project grows: doubling the files doubles the cost and does no worse. What changes between them is the constant.

## Where the difference comes from

The two ports run the identical algorithm. Every stage does the same work in the same order, against the same SHA-256, and produces byte-for-byte the same output. So none of the difference is algorithmic; all of it is what the language and runtime cost to do that work.

**Startup dominates a real invocation.** A warm check on 2002 files is about 12ms of work in Zig. In the TypeScript it is about 43ms of work sitting behind 36ms of runtime startup. For a tool invoked once per commit, or once per suite in a build script, that fixed cost is paid every single time and no amount of optimisation inside the tool removes it.

**The warm hash path is a stat and a map lookup, and that is where the widest gap is** (9.8x). There is almost no work per file there, so what is being measured is close to the per-operation overhead of each language: a syscall plus a hash lookup, with the string handling and object allocation around it. Zig does that with a stack `statx` and a slice compare; the TypeScript allocates a stats object per file and goes through the async machinery for each one.

**Cold hashing is 6.4x** despite being dominated by reading files, which both do through the same kernel. The gap is the per-file cost around the read: Zig streams into a fixed 64KB buffer and never allocates, while the TypeScript reads each file into a fresh Buffer and hands it to a new hash object.

**Building the hash tree is 3.1x**, the smallest gap of the substantial stages, because it is dominated by allocating and inserting into maps, which both runtimes do reasonably well.

**Memory is where Zig makes the difference cheaply.** The whole run uses one arena, freed once at exit. Nothing in this tool needs anything freed before the process ends, so there is no per-object bookkeeping and no garbage collector to run at all. That is not cleverness on the port's part; it is a fit between the tool's lifetime and the allocation strategy that the TypeScript cannot express.

## What it means in practice

Against a test suite of about three and a half minutes, a warm check costs **0.006%** of the thing it is deciding about in Zig, against **0.04%** in the TypeScript. Both are far below the point where anyone would notice. The honest summary is that this port makes an already-negligible cost more negligible.

Where it does matter:

- **Pre-commit hooks**, where 80ms against 12ms is the difference between a hook that feels instant and one that has a perceptible pause.
- **Scripts that call it many times.** A build that asks per package, or captures a baseline per target as each passes, multiplies the fixed startup cost by the number of calls. Twelve concurrent captures cost roughly a second of runtime startup in the TypeScript and essentially nothing in Zig.
- **CI images**, where a 4MB binary against a 90MB one is a real difference in what has to be pulled.

Where it does not matter: a single check in a build that already takes minutes.

## Why it is as fast as it is

**The warm path never opens a file.** `hashFile` stats the file and compares `mtime_ms` and `size` against the cache. Both matching means the recorded hash is returned without a read. That is the difference between the cold and warm rows above: 2.9us per file versus 0.8us, and the 0.8us is essentially one `statx` syscall.

**The tree is built once and queried many times.** Building it is about 0.4us per file and does not depend on how many targets there are. Answering "did anything under this path change" is then a walk of the path's segments, which is why the lookup row is flat no matter how many watched paths a config has.

**Nothing is recomputed between stages.** The run carries the hashes it computed, so recording them after a passing run needs no second pass over the tree.

**One arena for the whole run.** Every allocation is needed until the run ends and none is needed after, which is exactly the case an arena is for. No function has to think about freeing, and no failure path can leak.

## Why it is not faster

The same two deliberate choices the TypeScript makes, and for the same reasons.

**Hashing is sequential.** The obvious optimisation is to hash across threads. In the steady state each file costs one `stat`, so the win is bounded by how well the kernel overlaps syscalls, and the cost is a thread pool to reason about and a file-descriptor ceiling to get wrong. At 16ms for 20000 files it is not worth it.

**The whole tree is hashed, not just what git says changed.** Git already stores a content hash per tracked file in its index, and `git ls-files -s` hands them over with no reads and no stats. That would remove most of the warm cost, and it is still not done, for the same two reasons the TypeScript documents:

- **Correctness.** Git measures change against HEAD, not against "the tree this target last passed on". After a commit the working tree is clean, so a git-status approach sees no changes; switch branch or pull, and it still sees no changes, and would skip everything while the tree underneath had completely changed.
- **Hash consistency.** Git blob hashes are SHA-1 over `blob <len>\0<content>`; these are plain SHA-256 over the content. The two cannot be mixed, because a file moving between clean and dirty would change hash without changing content and trigger a spurious run.

## The budget

`perf-tests/run.zig` fails if warm hashing exceeds **0.15ms per file**, which is the same budget the TypeScript uses so the two can be held to one standard. Measured values here sit around 0.0008ms, so there is roughly a two-hundredfold margin. The budget is set loose on purpose: it is there to catch a change that makes the warm path read files again, which would show up as a jump to the cold numbers, not to police small variations between machines.

## Reproducing

```bash
zig build perf
```

The harness writes throwaway trees under the system temp directory and removes them afterwards. Sizes run 100, 1000, 5000 and 20000 files, and each size measures cold hashing, warm hashing, tree building, watched-path lookup, and the changed-file diff both when nothing changed and when one file did.

The end-to-end numbers at the top were measured by driving both ports' executables as real processes against one generated 2002-file git repository, ten runs each, taking the median.

## Same answers, not just faster ones

A speed comparison is worth nothing if the two are not doing the same job, so the outputs were checked as well as the timings.

Both were driven through about sixty invocations covering every command, every output format and every error path, against the same generated repository, and their output diffed. It is byte-for-byte identical, including every report, every JSON and YAML rendering, every error message and every exit code, except for two messages:

| | TypeScript | This implementation |
| --- | --- | --- |
| Malformed YAML config | `what-changed config is not valid YAML: Sequence item without - indicator at line 3, column 1: ...` | `what-changed config is not valid YAML: this line is indented further than the block it follows, so nothing owns it at line 3, column 4` |
| Malformed JSON config | `what-changed config is not valid JSON: JSON Parse error: Expected '}'` | `what-changed config is not valid JSON: it holds a character that cannot appear there` |

Both refuse the same configs, with the same message prefix and the same exit code. Only the diagnostic after the colon differs, because it comes from a different parser. Matching it exactly would have meant reproducing another library's error formatting, for text that nothing parses.

The scenarios in `scripts/smoke-tests.sh` were also run against both, unchanged, and pass for both.

## Measurement caveats

- Both ports were measured on the same machine, in the same session, against trees generated by the same rules. They were not run simultaneously.
- The Zig binary is built with `ReleaseFast`. A `Debug` build is several times slower, because the safety checks are real work; do not benchmark one.
- Single measured runs are quoted for the stage table, matching how the TypeScript project reports its own. The whole stage table was produced three times for both ports; values moved by a few percent and no ratio moved enough to matter.
- The end-to-end table is medians of ten runs, repeated twice. The one number in it that is not timed the same way is the executable size, which is just the file on disk.
- Filesystem caches are warm for both, since the trees are written immediately before being measured. Cold-disk numbers would be dominated by the disk and would say nothing about either port.
