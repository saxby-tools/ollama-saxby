#  ollama-saxby

A way to find Ollama bugs on real hardware, fix them upstream, and run
the fix until the release that carries it. Saxby's maintainer runs
Ollama this way; anyone may.

Every patch here is a commit on an open pull request against
[ollama/ollama](https://github.com/ollama/ollama). The patch exists so
the fix can run, and be watched, on the machine that found the bug
while the PR is in review. It is dropped the moment upstream releases
it. This is not a fork, and nothing lives here that upstream has not
been offered.

The mechanics are a build script in the spirit of an Arch PKGBUILD:
upstream's release tag, plus the patches in [`patches/`](patches),
applied and built on your machine. CI moves it to each new Ollama
release on its own and opens an issue only when a patch stops applying.

##  The patches

| Patch | Upstream PR | Fixes |
| --- | --- | --- |
| 0001 | [ollama#19327](https://github.com/ollama/ollama/pull/19327) | The memory estimate sized every layer's KV cache the same way, at f16 and full context: gemma4:31b predicted 57.9 GiB, used 31.0 |
| 0002 | [ollama#19327](https://github.com/ollama/ollama/pull/19327) | The sliding-window term ignored an explicit num_batch, which reaches llama-server as -ub; a review fix carried with 0001 |
| 0003 | [ollama#19324](https://github.com/ollama/ollama/pull/19324) | Only the last chunk of each buffer was counted: 5.8 GiB tracked for a model using about 33 GiB |
| 0004 | [ollama#19325](https://github.com/ollama/ollama/pull/19325) | On Metal, free memory was re-checked before macOS returned it, so one eviction became two |
| 0005 | [ollama#19419](https://github.com/ollama/ollama/pull/19419) | MLX models skipped the memory pre-flight and were booked at their weights: qwen3.8:27b booked at 16.9 GiB reached 78.8 GiB and the kernel panicked |

Each one started as a problem seen on a running machine, was traced to
its cause in Ollama, and went upstream as a PR with the measurements
that found it. A patch disappears from this table, and from
`patches/`, once upstream releases it.

Each file name ends in the number of the PR it rides on. One patch per
PR is the rule; when a review fix has to travel as its own commit, as
0002 does on 19327, the shared suffix shows the two files are one PR.
[`MAINTAINING.md`](MAINTAINING.md) is the routine that keeps the set
equal to the open PRs.

##  Build

Needs git, Go, CMake, a C/C++ compiler, and Ninja if you have it. On
macOS, the MLX engine also needs Xcode and its Metal Toolchain
(`xcodebuild -downloadComponent MetalToolchain`). Without it the build
stops and says so, since a build without MLX cannot load safetensors
models; pass `--no-mlx` if that is what you want. An Xcode update
removes the toolchain, so expect to download it again after one.

```bash
./build.sh
```

That builds the release in [`ollama.version`](ollama.version), the
newest one CI has verified, and installs it to
`~/.local/opt/ollama-saxby/<tag>-p<patch set>`, with a `current` link
pointing at it. Each build gets its own folder, so a running Ollama is
never overwritten, and rolling back is moving the link.

| Option | Does |
| --- | --- |
| `--tag latest` | Newest final release right now, verified or not |
| `--tag v0.40.13-rc0` | Any tag you name, release candidates included |
| `--prepare-only` | Apply the patches and run the tests; no build |
| `--no-mlx` | Skip the MLX engine |
| `--backends "cuda_v13;vulkan"` | GPU backends on Linux |
| `--prefix DIR` | Install somewhere else |

Run `./build.sh --help` for the rest.

##  Run it

The script installs binaries and nothing else. Whatever starts Ollama
on your machine keeps doing so; point it at
`~/.local/opt/ollama-saxby/current/bin/ollama` and restart it.

On macOS with your own LaunchAgent (its environment, such as
`OLLAMA_KEEP_ALIVE`, stays in the plist):

```xml
<key>ProgramArguments</key>
<array>
    <string>/Users/YOU/.local/opt/ollama-saxby/current/bin/ollama</string>
    <string>serve</string>
</array>
```

```bash
launchctl kickstart -k gui/$(id -u)/<your label>
```

On Linux with a user unit, set `ExecStart` to the same path, then
`systemctl --user restart <your unit>`.

To go back to stock Ollama, point the service at your packaged
`ollama` again.

##  How CI keeps it current

[`release-check`](.github/workflows/release-check.yml) runs daily:

1. Finds Ollama's newest final release.
2. Applies each patch with a three-way merge. A patch that applies in
   reverse is already upstream, and is dropped.
3. Runs Ollama's `llm` and `server` tests on the result.
4. If everything passes, rewrites `patches/` against the new release,
   moves `ollama.version` and pushes. A macOS job then does the full
   native build.
5. If anything fails, it opens one issue per release and pins nothing.
   A later passing run closes that issue.

Run it by hand from the Actions tab to check any tag; a named tag never
moves the pin.

##  License

MIT, matching Ollama, since every patch here is already on its way
upstream.
