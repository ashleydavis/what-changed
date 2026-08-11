# Example configurations

This directory contains the same configuration written two ways. what-changed reads whichever it finds and choses the parser by the file's extension.

| File | Format |
| --- | --- |
| [what-changed.yaml](what-changed.yaml) | YAML. Also accepted as `.yml` |
| [what-changed.json](what-changed.json) | JSON |

Copy one to the root of your project, next to your `.git` directory, and edit the targets.

With no `--config` given, the tool looks for `what-changed.yaml`, then `what-changed.yml`, then `what-changed.json`, and uses the first it finds. Point it anywhere else with `--config <path>`.

One path needs adding to your `.gitignore`, whichever format you use:

```
.what-changed/
```

That directory holds two things. 
- `baseline.json` records a basline of successful builds and tests against each target.
- `cache/` only affects how fast a run is. The cache has its own subdirectory so `cache reset` can never reach the baseline.

You can delete `.what-changed/` at any time to reset the baseline and cache.

For these fields in a project you can actually run, see [`../example-project/`](../example-project/).
