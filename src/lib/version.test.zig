const std = @import("std");
const version = @import("version.zig");
const testing = std.testing;

//
// These check that the values reach the code, not what they are. Asserting "dev" would fail on
// exactly the builds that ship, since the release workflow rewrites this file before compiling.
//
test "the version is a non-empty string" {
    try testing.expect(version.version.len > 0);
}

test "the build metadata is filled in" {
    try testing.expect(version.build_metadata.commit_hash.len > 0);
    try testing.expect(version.build_metadata.build_date.len > 0);
}
