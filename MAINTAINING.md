#  Maintaining

The checklist for the recurring maintainer pass. Everything here is
read-only until the last section; nothing in it loads a model or
restarts a service without saying so.

This is not a fork. Every patch is a commit on an open PR against
ollama/ollama, and the patch set exists only until upstream releases
each one. One patch per PR is the rule.

##  Where things are

| Thing | Where |
| --- | --- |
| Patches, build script, CI | github.com/saxby-tools/ollama-saxby, checked out at `~/Workspaces/ollama-saxby` |
| PR branches | github.com/saxby-tools/ollama, a GitHub fork that exists to hold PR heads; its `main` stays equal to upstream, the upstream branches it was forked with are left alone, and Actions are off |
| Local Ollama clone | `~/Workspaces/ollama`: remote `origin` is ollama/ollama, remote `saxby` is the PR-branch fork, remote `fork` is the older personal fork that still holds the three PRs opened from it |
| Production binary | `~/.local/opt/ollama-saxby/current/bin/ollama`, started by the `local.ollama` LaunchAgent, log at `/opt/homebrew/var/log/ollama.log` |

##  Each pass

1. **PR state.** For every file in `patches/`, the `-prNNNNN` suffix
   names its PR. Check each one:

   ```bash
   gh pr list --repo ollama/ollama --author nikolowry --state all
   ```

   Merged: nothing to do; the next release that contains it makes the
   patch apply in reverse and `release-check` drops it. Closed without
   merge: read why, and decide whether to carry it or drop it. New
   review comments: answer them, fix on the PR branch in
   `~/Workspaces/ollama`, push to `saxby`, then regenerate the patch
   (next section).

2. **Patch set equals PR set.** `ls patches/` should show one file per
   open PR. Two files with the same suffix mean a review fix travelled
   as its own commit; that is allowed, and the README table says so.
   A file with no suffix is missing its `Ollama-PR:` trailer.

3. **Fork main equals upstream.**

   ```bash
   gh repo sync saxby-tools/ollama --source ollama/ollama
   ```

   The fork never gets commits of its own on `main`.

4. **Release pin.** `ollama.version` is the newest release CI has
   verified. If `release-check` opened an issue in ollama-saxby, a
   patch stopped applying on a new release; rebase it on the PR branch
   and regenerate.

5. **Production version.** Compare the running build with the pin:

   ```bash
   ~/.local/opt/ollama-saxby/current/bin/ollama --version
   ```

   The version reads `<tag>+saxby.<patch set id>`; the id is a hash of
   the patch files, so a refresh that only renumbers headers changes it
   too. Rebuild and restart when the pin moved or a patch's diff
   changed, not for a header-only refresh. Both touch the running
   service, so say so before doing them:

   ```bash
   ./build.sh
   ```

   ```bash
   launchctl kickstart -k gui/$(id -u)/local.ollama
   ```

   `build.sh` installs into a new folder and moves `current`; the old
   folder stays for rollback.

##  Adding or regenerating a patch

1. In `~/Workspaces/ollama`, branch off `origin/main`, commit the
   change, and push the branch to `saxby`.
2. Open the PR with the fork as head:

   ```bash
   gh pr create --repo ollama/ollama --base main --head saxby-tools:<branch>
   ```

3. In `~/Workspaces/ollama-saxby`, write the patch with
   `git format-patch` and add an `Ollama-PR:` trailer to its commit
   message, after the `Co-Authored-By` line and before the `---`:

   ```
   Ollama-PR: https://github.com/ollama/ollama/pull/<number>
   ```

4. Apply the set and let the refresh name the files:

   ```bash
   ./build.sh --prepare-only --refresh
   ```

   That runs Ollama's `llm` and `server` tests, rewrites `patches/`
   against the pinned tag and adds the `-prNNNNN` suffix from the
   trailer.

5. Add a row to the README table, commit one file per commit, push.
