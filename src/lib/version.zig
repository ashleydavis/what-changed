//
// Which build this is.
//
// The values are placeholders that a release build rewrites, so a working copy reports that it is
// not a release rather than claiming a version it does not have.
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

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("version.test.zig");
}
