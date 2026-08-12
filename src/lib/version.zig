const std = @import("std");

//
// Which build this is.
//
// Mirrors src/lib/version.ts. The values are placeholders that a release build rewrites, so a
// working copy honestly reports that it is not a release rather than claiming a version it does not
// have.
//

//
// Version is set by the CI build process. "dev" is used for local development.
//
pub const version = "dev";

//
// What a release build records about itself.
//
pub const BuildMetadata = struct {
    //
    // The commit the build came from, or "dev" when it was not built by CI.
    //
    commit_hash: []const u8,

    //
    // When the build happened, or "development" when it was not built by CI.
    //
    build_date: []const u8,

    //
    // Whether this is a pre-release rather than a tagged release.
    //
    is_pre_release: bool,
};

//
// Build metadata is set by the CI build process.
//
pub const build_metadata = BuildMetadata{
    .commit_hash = "dev",
    .build_date = "development",
    .is_pre_release = false,
};

const testing = std.testing;

//
// These check that the values reach the code, not what they are. Asserting "dev" would fail on
// exactly the builds that ship, since the release workflow rewrites this file before compiling.
//
test "the version is a non-empty string" {
    try testing.expect(version.len > 0);
}

test "the build metadata is filled in" {
    try testing.expect(build_metadata.commit_hash.len > 0);
    try testing.expect(build_metadata.build_date.len > 0);
}
