# Contributing to MongrelDB Lua

Thanks for taking the time to help the MongrelDB Lua client. This document
describes how to propose a change, what we expect from a pull request, and
the coding standards that apply to the codebase.

If anything here is unclear or out of date, open an issue or a PR.

## Code of conduct

Be kind, be specific, assume good faith. Disagree about the technical
details, not the person. Public reviews stay focused on the diff.

## How to propose a change

The MongrelDB Lua client uses a standard **fork, branch, pull request**
workflow on GitHub.

1. **Fork** [`visorcraft/MongrelDB-Lua`](https://github.com/visorcraft/MongrelDB-Lua)
   to your GitHub account.
2. **Clone** your fork and add the upstream remote:

   ```sh
   git clone git@github.com:<you>/MongrelDB-Lua.git
   cd MongrelDB-Lua
   git remote add upstream https://github.com/visorcraft/MongrelDB-Lua.git
   ```

3. **Branch** from `master`. Pick a descriptive, kebab-case branch name:
   `fix-query-builder-alias`, `feature/sparse-vector`, `docs/auth-guide`.

   ```sh
   git fetch upstream
   git switch -c my-change upstream/master
   ```

4. **Make focused commits.** One logical change per commit. Run the
   preflight (see below) before pushing.
5. **Open a pull request** against `master` on `visorcraft/MongrelDB-Lua`.
   Fill in the PR template:
   - **What.** One paragraph summary of the change.
   - **Why.** Bug fix? New feature? Doc fix? Link the issue if one
     exists.
   - **How to test.** The exact commands a reviewer should run.
   - **Risk.** What might break? What did you not test?

## Before you push: preflight

Run the full CI preflight locally:

```sh
luarocks install luasocket --local
luacheck src tests
lua tests/json_test.lua
```

All steps must pass with zero warnings. If a check fails, fix the root
cause, do not silence the linter or skip the test.

To run the live integration suite (requires a running `mongreldb-server`):

```sh
MONGRELDB_URL=http://127.0.0.1:8453 lua tests/live_test.lua
```

Live tests self-skip when `MONGRELDB_URL` is unset or unreachable.

## What we look for in a review

- The change does one thing and does it well.
- Behavior changes ship with tests. New client behavior: a test in `tests/`.
  Daemon-dependent coverage: a live test that skips cleanly when no server is
  available.
- The change keeps this repo a thin client over `mongreldb-server`. Do not
  re-implement storage, indexing, WAL, or SQL planning logic here.
- Documentation is updated alongside the code (`docs/`, `README.md`) if the
  change affects users.
- Commits have clear messages (see below).

## Coding standards

### Lua

- **Version.** Lua 5.3+ or LuaJIT. Do not drop the minimum casually.
- **Style.** Indent with two spaces. Keep lines under 90 columns. Run
  `luacheck` with no warnings.
- **Naming.** `snake_case` for functions and variables. Method calls use the
  colon syntax (`db:put(...)`).
- **Transport.** Keep transport-specific behavior behind the LuaSocket call
  site, and raise the existing typed error objects instead of bare `error()`
  with strings.
- **Dependencies.** Prefer the Lua standard library and LuaSocket. New
  dependencies must be MIT or Apache-2.0 licensed.

### Commit messages

- Conventional Commit-style subjects: `fix(query): ...`, `test: ...`,
  `ci: ...`. Keep subjects concise and imperative.
- Subject line at most 72 characters, no trailing period.
- Body: wrap at 72 characters. Explain *why*, not *what* (the diff
  shows the what).
- Reference issues with `Fixes #123` / `Refs #123` on a final line
  when applicable.
- **Never** add AI/assistant attribution (no `Co-Authored-By`, no
  `Generated with`, no tool names).

## Issue reports

A useful bug report includes:

- The MongrelDB Lua client version (from the rockspec).
- Your Lua version (`lua -v`) and OS.
- The `mongreldb-server` version if the issue involves live requests.
- The exact code or commands that reproduce the issue.
- The expected result and the actual result.
- Any error output or stack trace.

Feature requests are welcome. Please describe the problem you are trying
to solve before proposing the solution.

## Security

If you find a vulnerability, **do not** open a public GitHub issue.
Report it privately through GitHub's private vulnerability reporting, the
repository's **Security** tab then **Report a vulnerability**. The full
policy is in [`SECURITY.md`](SECURITY.md).

## Licensing

The MongrelDB Lua client is dual-licensed under MIT OR Apache-2.0. By
contributing, you agree that your changes are made available under the
same license.

- Do **not** paste code from other database clients unless you have done a
  license review first.
- New third-party dependencies must be MIT or Apache-2.0 licensed.

Thanks again, looking forward to your PR.
