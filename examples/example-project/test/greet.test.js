import { test } from "node:test";
import assert from "node:assert/strict";
import { greet } from "../src/greet.js";

//
// One test, so the example has a suite that either passes or fails. Node runs it with `node --test`
// and no test framework to install.
//
test("greet names the person it is greeting", () => {
    assert.equal(greet("world"), "Hello, world!");
});
