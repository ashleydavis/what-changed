const std = @import("std");
const init = @import("init.zig");
const testing = std.testing;
const harness = @import("harness.zig");
const wc = @import("what-changed");

test "writeStarterConfig writes a config when the project has none" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const step = try init.writeStarterConfig(scenario.io(), scenario.allocator(), scenario.temporary.path, &scenario.fail);
    try testing.expectEqual(init.InitStep.created, step);

    const written = try scenario.temporary.read(scenario.allocator(), init.STARTER_CONFIG_NAME);
    try testing.expectEqualStrings(init.STARTER_CONFIG, written);
}

test "writeStarterConfig leaves an existing config exactly as it was" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const original = "targets:\n  - name: tuned\n    paths:\n      - lib\n";
    try scenario.write("what-changed.yaml", original);

    const step = try init.writeStarterConfig(scenario.io(), scenario.allocator(), scenario.temporary.path, &scenario.fail);
    try testing.expectEqual(init.InitStep.already_present, step);

    //
    // Byte for byte, because a config someone has tuned is not recoverable once it has been written
    // over, and "did not overwrite" is the whole safety of this step.
    //
    try testing.expectEqualStrings(original, try scenario.temporary.read(scenario.allocator(), "what-changed.yaml"));
}

test "writeStarterConfig counts every name the tool looks for as a config" {
    //
    // A project with a .yml or .json config is set up. Writing a .yaml beside it would take
    // precedence over the config that project has been using, which is a silent change of answer.
    //
    for ([_][]const u8{ "what-changed.yml", "what-changed.json" }) |name| {
        var scenario = try harness.Scenario.create();
        defer scenario.destroy();

        try scenario.write(name, "targets:\n  - name: tuned\n    paths:\n      - lib\n");

        const step = try init.writeStarterConfig(scenario.io(), scenario.allocator(), scenario.temporary.path, &scenario.fail);
        try testing.expectEqual(init.InitStep.already_present, step);
        try testing.expect(!scenario.temporary.has("what-changed.yaml"));
    }
}

test "the config writeStarterConfig writes loads and holds the targets it names" {
    //
    // What stops the template drifting into something the parser rejects: a starter config that
    // does not load makes the tool unusable for exactly the people who have never used it.
    //
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    _ = try init.writeStarterConfig(scenario.io(), scenario.allocator(), scenario.temporary.path, &scenario.fail);

    const config_path = try scenario.temporary.join(scenario.allocator(), init.STARTER_CONFIG_NAME);
    const config = try wc.config.loadConfig(scenario.io(), scenario.allocator(), config_path, &scenario.fail);

    try testing.expectEqual(@as(usize, 2), config.targets.len);
    try testing.expectEqualStrings("compile", config.targets[0].name);
    try testing.expectEqualStrings("test", config.targets[1].name);
}

test "addGitignoreEntry writes a .gitignore when there is none" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const step = try init.addGitignoreEntry(scenario.io(), scenario.allocator(), scenario.temporary.path, &scenario.fail);
    try testing.expectEqual(init.InitStep.created, step);

    try testing.expectEqualStrings(".what-changed/\n", try scenario.temporary.read(scenario.allocator(), ".gitignore"));
}

test "addGitignoreEntry appends to a .gitignore that does not ignore it yet" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write(".gitignore", "node_modules/\ndist/\n");

    const step = try init.addGitignoreEntry(scenario.io(), scenario.allocator(), scenario.temporary.path, &scenario.fail);
    try testing.expectEqual(init.InitStep.created, step);

    try testing.expectEqualStrings(
        "node_modules/\ndist/\n.what-changed/\n",
        try scenario.temporary.read(scenario.allocator(), ".gitignore"),
    );
}

test "addGitignoreEntry starts a new line when the file does not end in one" {
    //
    // Without this the entry lands on the end of somebody else's line, which silently changes what
    // that line ignores and leaves .what-changed/ ignored by nothing.
    //
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write(".gitignore", "dist/");

    _ = try init.addGitignoreEntry(scenario.io(), scenario.allocator(), scenario.temporary.path, &scenario.fail);

    try testing.expectEqualStrings("dist/\n.what-changed/\n", try scenario.temporary.read(scenario.allocator(), ".gitignore"));
}

test "addGitignoreEntry leaves a file that already ignores it exactly as it was" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const original = "node_modules/\n.what-changed/\ndist/\n";
    try scenario.write(".gitignore", original);

    const step = try init.addGitignoreEntry(scenario.io(), scenario.allocator(), scenario.temporary.path, &scenario.fail);
    try testing.expectEqual(init.InitStep.already_present, step);
    try testing.expectEqualStrings(original, try scenario.temporary.read(scenario.allocator(), ".gitignore"));
}

test "addGitignoreEntry recognises the entry however it is written" {
    //
    // Git honours the name with and without the trailing slash, and ignores the whitespace around
    // it. Not recognising a spelling git honours would add a second line saying the same thing.
    //
    for ([_][]const u8{ ".what-changed\n", "  .what-changed/  \n", "\t.what-changed/\r\n" }) |contents| {
        var scenario = try harness.Scenario.create();
        defer scenario.destroy();

        try scenario.write(".gitignore", contents);

        const step = try init.addGitignoreEntry(scenario.io(), scenario.allocator(), scenario.temporary.path, &scenario.fail);
        try testing.expectEqual(init.InitStep.already_present, step);
        try testing.expectEqualStrings(contents, try scenario.temporary.read(scenario.allocator(), ".gitignore"));
    }
}

test "initCommand writes both files and names them" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    try testing.expectEqual(@as(u8, 0), try init.initCommand(&context));

    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "what-changed.yaml") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), ".gitignore") != null);
    try testing.expect(scenario.temporary.has("what-changed.yaml"));
    try testing.expect(scenario.temporary.has(".gitignore"));
}

test "initCommand succeeds on a project that is already set up" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write("what-changed.yaml", "targets:\n  - name: tuned\n    paths:\n      - lib\n");
    try scenario.write(".gitignore", ".what-changed/\n");

    const context = scenario.context();

    //
    // Not a failure: finding the project already set up is a successful answer to "set this project
    // up", and a build script that runs init before anything else must not fail on the second run.
    //
    try testing.expectEqual(@as(u8, 0), try init.initCommand(&context));
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "already has a what-changed config") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "already ignores") != null);
}

test "initCommand run twice leaves both files as the first run wrote them" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    _ = try init.initCommand(&context);

    const config_after_first = try scenario.temporary.read(scenario.allocator(), "what-changed.yaml");
    const gitignore_after_first = try scenario.temporary.read(scenario.allocator(), ".gitignore");

    scenario.clear();
    _ = try init.initCommand(&context);

    try testing.expectEqualStrings(config_after_first, try scenario.temporary.read(scenario.allocator(), "what-changed.yaml"));
    try testing.expectEqualStrings(gitignore_after_first, try scenario.temporary.read(scenario.allocator(), ".gitignore"));
}
