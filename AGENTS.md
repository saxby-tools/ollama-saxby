#  ollama-saxby: notes for agents

[`README.md`](README.md) says what this repo is and how to build.
[`MAINTAINING.md`](MAINTAINING.md) is the recurring checklist and the
conflict steps. This file holds what neither says and an agent needs
before changing anything. Read all three first; do not work from
memory of an earlier session.

##  Where each PR lives

Every patch is a commit on an open PR against ollama/ollama, and those
PR branches live in **two different forks**. A fix pushed to the wrong
one never reaches the PR.

| PR | Patch | Head repository | Remote in `~/Workspaces/ollama` |
| --- | --- | --- | --- |
| [19327](https://github.com/ollama/ollama/pull/19327) | 0001, 0002 | nikolowry/ollama | `fork` |
| [19324](https://github.com/ollama/ollama/pull/19324) | 0003 | nikolowry/ollama | `fork` |
| [19325](https://github.com/ollama/ollama/pull/19325) | 0004 | nikolowry/ollama | `fork` |
| [19419](https://github.com/ollama/ollama/pull/19419) | 0005 | saxby-tools/ollama | `saxby` |

The first three were opened from the maintainer's personal fork before
saxby-tools/ollama existed. A PR's head cannot be moved to another
repository, so they stay there until merged or closed. **Every new PR
is opened from saxby-tools/ollama.** `origin` is upstream and is never
pushed to.

Do not trust this table over GitHub. Before pushing, ask which
repository holds the head:

```bash
gh pr view <number> --repo ollama/ollama \
    --json headRepositoryOwner,headRefName,state,mergeable
```

Update the table when a PR is opened, merged or closed.

##  Check every open PR on every pass

The daily CI checks the patches against Ollama's releases. **Nothing
automated watches the PRs themselves.** PR 19324 sat in conflict with
`main`, and a review comment on 19327 sat unanswered, until a release
broke the patch set. So start any work here with:

```bash
gh pr list --repo ollama/ollama --author nikolowry --state all \
    --json number,state,mergeable,headRepositoryOwner,reviews,comments
```

That lists PRs from both forks. For each open one, look at:

- `mergeable`. `CONFLICTING` means the branch needs a rebase on
  `origin/main` now, whether or not a release has shipped the change.
- Reviews and comments since the last pass. Inline review comments,
  review summaries and plain PR comments are three separate lists:
  `gh api repos/ollama/ollama/pulls/<n>/comments`, `.../pulls/<n>/reviews`
  and `.../issues/<n>/comments`.
- Whether it merged or closed. A merged PR's patch is dropped by CI on
  the release that contains it; a closed one needs a decision.

Ollama runs CI on a fork's PR only after a maintainer approves it, so
"no checks" is normal and says nothing about the code.

##  Rules that are easy to break

- **A patch is its PR's commit.** Never edit a file in `patches/` by
  hand. Change the PR branch, then regenerate the patch from it.
- **Patches are written against `ollama.version`.** `build.sh` applies
  them on that release first, then rebases them onto the tag being
  built. A patch that does not apply on the pin, in its place in the
  set, breaks every build. The pin and `patches/` change together, in
  one commit.
- **One patch per PR**, each ending in an `Ollama-PR:` trailer. The
  refresh names files from that trailer; a file with no `-prNNNNN`
  suffix lost it.
- **CI commits to `main`.** A passing daily run pushes "Pin Ollama
  vX and refresh patches". Pull before working, or the push conflicts.
- **`build.sh` installs binaries and nothing else.** It never starts,
  stops or configures a service, and no change here should make it.
- **This is not a fork.** Nothing lands here that upstream has not
  been offered as a PR first.

##  A clean merge is not a passing patch

CI proves a patch still applies and Ollama's tests still pass. It does
not prove the patch still does its job. On v0.40.15, patch 0003 would
have merged with a one-line comment fix, and been wrong: llama.cpp
b12111 began printing a rotation buffer line after each KV cache, and
0003 added up only adjacent lines, so it would have gone back to
undercounting a model by gigabytes. Its own tests did not cover the
new log order, so they passed.

When a release changes `LLAMA_CPP_VERSION`, read what changed for each
patch that depends on llama.cpp's behaviour:

- 0001 and 0002 mirror how llama.cpp sizes the KV cache
  (`src/llama-kv-cache*.cpp`, `src/llama-model.cpp`).
- 0003 parses llama-server's "buffer size" log lines.

Ollama does not vendor llama.cpp; read it at the pinned tag:

```bash
gh api "repos/ggml-org/llama.cpp/contents/<path>?ref=<tag>" \
    --jq .content | base64 -d
```

An estimate that runs low is the dangerous direction: the scheduler
then loads a model that does not fit.

##  What the scripts do that is not obvious

- `src/` holds one shallow checkout per tag and is disposable. The
  patches become unsigned commits there under a throwaway identity.
  After a conflict the rebase is left stopped in it on purpose; the
  next ordinary run aborts it and starts over.
- Exit codes: 2 a patch does not apply or rebase, 3 Ollama's tests
  fail, 4 no Metal Toolchain, 64 bad usage. CI's alert text depends on
  2 and 3.
- `--refresh` writes `patches/` and the pin after the tests, so a set
  that fails them is never written back. A second refresh of the same
  commits is byte-identical; a diff after one means something changed.
- The tests run with every `OLLAMA_*` variable unset, because the
  maintainer's settings change what the scheduler tests expect. Do the
  same when running `go test` by hand.
- CI: a push re-checks the pinned release only. The daily run and a
  manual run with no tag may move the pin; a manual run with a tag
  never does. The macOS native build runs only when the pin moves or
  on a manual run, and takes about an hour on GitHub's runner.
- The alert is one issue per release, titled "Patches fail on Ollama
  <tag>". A later passing run for that tag closes it; do not close it
  by hand.

##  Writing shell here

`build.sh` must run under the bash 3.2 that macOS ships: no
associative arrays, no `mapfile`, no empty-array expansion under
`set -u`. Call `/usr/bin/grep` by path, since an interactive shell may
alias `grep` to a tool that reads options differently. Hard 80-column
limit, constants at the top, functions in call order.

Before committing:

```bash
shellcheck build.sh ci/alert.sh
```

```bash
actionlint .github/workflows/release-check.yml
```

```bash
./build.sh --prepare-only
```

The last one applies the set and runs the tests in about 30 seconds.
It loads no model and builds nothing native.

##  The machine this runs on

The maintainer's Mac runs the build from this repo as its production
Ollama, behind the `local.ollama` LaunchAgent.

- A full `./build.sh` takes two to four minutes at full CPU. A restart
  unloads every model. Say so before either, and do neither to test a
  change: `--prepare-only` is enough.
- Production must include the MLX engine. Safetensors models run on
  it, and a build without it cannot load them. `build.sh` stops rather
  than drop MLX; do not pass `--no-mlx` for a production build.
- An Xcode update removes the Metal Toolchain. The fix is
  `xcodebuild -downloadComponent MetalToolchain`.
- `xcode-select` points at the Command Line Tools, which have no Metal
  compiler. `build.sh` sets `DEVELOPER_DIR` to the full Xcode for its
  own run; do the same for a manual `cmake` or `go build`.
- CMake caches the backend options in the reused `build/` folder.
  `build.sh` unsets the ones not passed; a manual `cmake` run must too.
- Stop a process you started by its PID. Never `pkill` or `killall` by
  pattern on this machine.
- The interactive shell is zsh with `noclobber` and `cp -i`/`rm -i`
  aliases, and `diff` is a function. In one-off commands use `>|`,
  `/bin/cp`, `/bin/rm` and `/usr/bin/diff`.

##  Commits and pushes

One commit per file, except files that only work together: the pin and
`patches/` always, a script and the workflow that calls it. Subjects
follow the log: `build:`, `patches:`, `ci:`, `docs:`. The body says
why.

Pushing is the maintainer's unless they have said otherwise. Hand over
the exact command with the right remote. A PR branch that was rebased
needs a force-push; give it with a lease on the old commit, so it
cannot overwrite work pushed in the meantime:

```bash
git push --force-with-lease=<branch>:<old sha> <remote> <branch>
```

Rewrite a PR branch only while nobody has reviewed it. Once a review
exists, add a commit instead, so the reviewer can see the change;
Ollama squash-merges, and the extra commit travels here as a second
patch with the same `-prNNNNN` suffix.
