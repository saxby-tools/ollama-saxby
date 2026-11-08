#!/usr/bin/env bash

#  =====================================================================
#  ollama-saxby
#  =====================================================================
#  Builds Ollama from an upstream release tag plus the patches in
#  patches/, in the spirit of an Arch PKGBUILD: a pinned source, then
#  prepare(), build(), check() and package().
#
#  It builds and installs binaries only. Whatever supervises Ollama
#  (a LaunchAgent, a systemd unit) stays yours; point it at the
#  installed `current` link and restart it.
#
#  Written for the bash 3.2 that macOS ships: no associative arrays,
#  no mapfile, no empty-array expansion under `set -u`.

set -euo pipefail

# ---------------------------------------------------------
# CONSTANTS
# ---------------------------------------------------------
PKGNAME="ollama-saxby"
UPSTREAM="https://github.com/ollama/ollama.git"

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH_DIR="$HERE/patches"
PIN_FILE="$HERE/ollama.version"
SRC_ROOT="$HERE/src"

DEFAULT_PREFIX="$HOME/.local/opt/$PKGNAME"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

# Patches land as throwaway local commits. They must not be signed and
# must not borrow the user's git identity.
SCRATCH_NAME="$PKGNAME"
SCRATCH_EMAIL="$PKGNAME@localhost"

# Exit codes the CI workflow reads.
EXIT_USAGE=64
EXIT_CONFLICT=2
EXIT_TESTS=3
EXIT_TOOLCHAIN=4

# ---------------------------------------------------------
# OPTIONS
# ---------------------------------------------------------
TAG_ARG="pinned"
PREFIX="$DEFAULT_PREFIX"
REFRESH=0
RESUME=0
STAGE="all"
SKIP_CHECK=0
NO_MLX=0
BACKENDS=""
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# Set by the steps below. The three lists hold commit subjects, one
# per line.
TAG=""
PIN=""
SRC=""
GIT_OUT=""
APPLIED=""
DROPPED=""
CONFLICTED=""

usage() {
    cat <<EOF
Usage: ./build.sh [options]

  --tag TAG         Ollama tag to build. "pinned" (default) is the
                    release in ollama.version, which CI moves to each
                    new final release once the patches pass. "latest"
                    is the newest final release right now. Any other
                    value is used as given, e.g. v0.40.13-rc0.
  --prefix DIR      Install root (default: $DEFAULT_PREFIX).
  --fetch-only      Stop after fetching the source.
  --prepare-only    Fetch, apply patches and run the Go tests; no
                    native build, no install. What CI runs.
  --refresh         After patches apply, rewrite patches/ against the
                    new tag and record it in ollama.version.
  --resume          Skip fetching and applying: take the commits now
                    on top of the tag in src/ as the patch set. For
                    after a conflict was resolved there by hand.
  --no-check        Skip the Go tests.
  --no-mlx          Build without the MLX engine (macOS).
  --backends LIST   GPU backends for Linux, e.g. "cuda_v13;vulkan".
  --jobs N          Parallel build jobs (default: $JOBS).
  -h, --help        Show this help.
EOF
}

log() {
    echo "==> $*" >&2
}

fail() {
    echo "error: $1" >&2
    exit "${2:-1}"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --tag) TAG_ARG="${2:?--tag needs a value}"; shift ;;
            --prefix) PREFIX="${2:?--prefix needs a value}"; shift ;;
            --fetch-only) STAGE="fetch" ;;
            --prepare-only) STAGE="prepare" ;;
            --refresh) REFRESH=1 ;;
            --resume) RESUME=1 ;;
            --no-check) SKIP_CHECK=1 ;;
            --no-mlx) NO_MLX=1 ;;
            --backends) BACKENDS="${2:?--backends needs a value}"; shift ;;
            --jobs) JOBS="${2:?--jobs needs a value}"; shift ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; fail "unknown option: $1" "$EXIT_USAGE" ;;
        esac
        shift
    done
}

# ---------------------------------------------------------
# TAG RESOLUTION
# ---------------------------------------------------------
# A final release has no suffix: v0.40.12, not v0.40.13-rc0.
latest_final_tag() {
    git ls-remote --tags --refs "$UPSTREAM" 'v*' |
        sed 's|.*refs/tags/||' |
        /usr/bin/grep -v -e '-' |
        sort -V |
        tail -1
}

resolve_tag() {
    PIN="$(tr -d '[:space:]' <"$PIN_FILE")"

    if [ "$TAG_ARG" = "pinned" ]; then
        TAG="$PIN"
        return
    fi

    if [ "$TAG_ARG" = "latest" ]; then
        TAG="$(latest_final_tag)"
        return
    fi

    TAG="$TAG_ARG"
}

# ---------------------------------------------------------
# FETCH
# ---------------------------------------------------------
# One shallow checkout per tag, so a rebuild of the same tag reuses
# CMake's build/ cache. Reset to the bare tag before applying patches.
fetch_source() {
    SRC="$SRC_ROOT/ollama-$TAG"

    if [ "$RESUME" -eq 1 ]; then
        log "Resuming in $SRC"
        return
    fi

    if [ ! -d "$SRC/.git" ]; then
        log "Fetching Ollama $TAG"
        mkdir -p "$SRC_ROOT"
        git -c advice.detachedHead=false clone -q --depth 1 \
            --branch "$TAG" "$UPSTREAM" "$SRC"
        return
    fi

    log "Reusing $SRC"
    git -C "$SRC" am --abort >/dev/null 2>&1 || true
    git -C "$SRC" rebase --abort >/dev/null 2>&1 || true
    git -C "$SRC" reset -q --hard "refs/tags/$TAG"
    git -C "$SRC" clean -q -fd
}

# ---------------------------------------------------------
# PREPARE
# ---------------------------------------------------------
# The patches are written against the pinned release, so they are
# applied there first, where they must apply exactly. To build any
# other tag the resulting commits are rebased onto it. That is a real
# three-way merge: git has both releases and every commit's parent, so
# it can carry a patch across upstream changes around it, and a patch
# upstream already contains comes out empty and is dropped. Applying
# the files straight onto the new tag cannot merge at all, since the
# versions the patches were cut from are not in that checkout.
scratch_git() {
    git -C "$SRC" -c user.name="$SCRATCH_NAME" \
        -c user.email="$SCRATCH_EMAIL" -c commit.gpgsign=false \
        -c advice.detachedHead=false "$@"
}

write_summary() {
    local summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

    {
        echo "### $PKGNAME on Ollama $TAG"
        echo
        echo "Applied:"
        echo "${APPLIED:-none}"
        echo
        echo "Dropped (already upstream):"
        echo "${DROPPED:-none}"
        echo
        echo "Conflicted:"
        echo "${CONFLICTED:-none}"
    } >>"$summary"
}

# Shows what git said, then stops. Nothing is built from a partial set.
fail_conflict() {
    cat "$GIT_OUT" >&2
    write_summary
    fail "$1" "$EXIT_CONFLICT"
}

apply_on_pin() {
    local patch name

    if [ "$PIN" != "$TAG" ]; then
        log "Fetching $PIN, the release the patches were written for"
        git -C "$SRC" fetch -q --depth 1 origin \
            "refs/tags/$PIN:refs/tags/$PIN"
        scratch_git checkout -q --detach "refs/tags/$PIN"
    fi

    for patch in "$PATCH_DIR"/*.patch; do
        [ -e "$patch" ] || continue
        name="$(basename "$patch")"

        if ! scratch_git am "$patch" >"$GIT_OUT" 2>&1; then
            scratch_git am --abort >/dev/null 2>&1 || true
            CONFLICTED="$name"
            fail_conflict "$name does not apply to $PIN, the release it \
was written for. Regenerate it against $PIN."
        fi

        log "Applied on $PIN: $name"
    done
}

# Sorts the commits that were on the pin into those still present on
# the new tag and those the rebase dropped as already upstream.
sort_applied_and_dropped() {
    local before="$1"
    local after subject

    after="$(scratch_git log --reverse --format=%s "refs/tags/$TAG..HEAD")"

    while IFS= read -r subject; do
        [ -n "$subject" ] || continue

        if printf '%s\n' "$after" | /usr/bin/grep -qxF -e "$subject"; then
            APPLIED="$APPLIED${APPLIED:+
}$subject"
            continue
        fi

        log "Already upstream, dropped: $subject"
        DROPPED="$DROPPED${DROPPED:+
}$subject"
    done <<EOF
$before
EOF
}

# On a conflict the rebase is left stopped in src/, so it can be
# resolved there and picked up with --resume. The next ordinary run
# aborts it and starts over.
move_to_tag() {
    local before

    before="$(scratch_git log --reverse --format=%s "refs/tags/$PIN..HEAD")"

    if [ "$PIN" = "$TAG" ]; then
        APPLIED="$before"
        return
    fi

    log "Rebasing the patches from $PIN onto $TAG"

    if scratch_git rebase --onto "refs/tags/$TAG" "refs/tags/$PIN" \
        >"$GIT_OUT" 2>&1; then
        sort_applied_and_dropped "$before"
        return
    fi

    CONFLICTED="$(scratch_git log -1 --format=%s REBASE_HEAD)"
    log "Conflict: $CONFLICTED"
    fail_conflict "the patches do not rebase onto $TAG. The rebase is \
stopped in $SRC: resolve it there and run 'git rebase --continue', then \
rerun with --resume, or fix the PR branch and regenerate the patch."
}

# --resume: a human finished the rebase by hand. Take what is there.
adopt_source() {
    if [ -d "$SRC/.git/rebase-merge" ] || [ -d "$SRC/.git/rebase-apply" ]; then
        fail "a rebase is still in progress in $SRC; finish it first"
    fi

    if [ -n "$(git -C "$SRC" status --porcelain --untracked-files=no)" ]; then
        fail "$SRC has uncommitted changes; commit or discard them first"
    fi

    if ! git -C "$SRC" merge-base --is-ancestor "refs/tags/$TAG" HEAD; then
        fail "the commits in $SRC are not on top of $TAG"
    fi

    APPLIED="$(scratch_git log --reverse --format=%s "refs/tags/$TAG..HEAD")"
    log "Adopting the commits on top of $TAG:"
    printf '%s\n' "$APPLIED" >&2
}

# Each patch names the upstream PR it rides on, as an Ollama-PR
# trailer in its commit message. The file name carries that number
# too, so a set that is not one patch per PR shows it at a glance:
# two files with the same -prNNNNN suffix are one PR.
suffix_patches() {
    local patch pr

    for patch in "$PATCH_DIR"/*.patch; do
        [ -e "$patch" ] || continue

        pr="$(sed -n -e 's|^Ollama-PR: .*/pull/\([0-9]*\)$|\1|p' \
            -e '/^---$/q' "$patch")"

        if [ -z "$pr" ]; then
            log "No Ollama-PR trailer: $(basename "$patch")"
            continue
        fi

        mv "$patch" "${patch%.patch}-pr$pr.patch"
    done
}

# Rewrites patches/ from the commits now on top of the tag, so the
# next release applies against fresh context. Dropped patches vanish
# because they produced no commit.
refresh_patches() {
    log "Refreshing patches against $TAG"
    rm -f "$PATCH_DIR"/*.patch
    git -C "$SRC" format-patch -q --zero-commit --no-signature \
        -o "$PATCH_DIR" "refs/tags/$TAG..HEAD"
    suffix_patches
    echo "$TAG" >"$PIN_FILE"
}

prepare() {
    GIT_OUT="$(mktemp)"

    if [ "$RESUME" -eq 1 ]; then
        adopt_source
    else
        apply_on_pin
        move_to_tag
    fi

    write_summary
}

# ---------------------------------------------------------
# BUILD
# ---------------------------------------------------------
# Names the patch set, so a build of the same tag with different
# patches gets its own version and install folder.
patch_set_id() {
    cat "$PATCH_DIR"/*.patch 2>/dev/null | shasum -a 256 | cut -c1-8
}

# xcode-select often points at the Command Line Tools, which lack
# Metal. Use the full Xcode for this build only, if it is installed.
use_xcode() {
    if [ -n "${DEVELOPER_DIR:-}" ]; then
        return
    fi

    if [ ! -d "$XCODE_DEVELOPER_DIR" ]; then
        return
    fi

    export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
}

has_metal_toolchain() {
    echo '__METAL_VERSION__' |
        xcrun -sdk macosx metal -E -x metal -P - >/dev/null 2>&1
}

# The version is stamped as SemVer build metadata (0.40.12+saxby.<id>),
# which version comparisons ignore, so clients still see the release.
build() {
    local args="-B build ."
    args="$args -DOLLAMA_VERSION=${TAG#v}+saxby.$(patch_set_id)"

    if command -v ninja >/dev/null 2>&1; then
        args="$args -G Ninja"
    fi

    if [ "$(uname -s)" = "Darwin" ]; then
        use_xcode

        # Fail rather than quietly build less: a build that silently
        # drops MLX cannot load safetensors models, and `current` would
        # move to it. An Xcode update also removes the toolchain.
        if [ "$NO_MLX" -eq 0 ] && ! has_metal_toolchain; then
            fail "no Metal Toolchain, so MLX cannot be built. Install it \
with 'xcodebuild -downloadComponent MetalToolchain', or pass --no-mlx." \
                "$EXIT_TOOLCHAIN"
        fi
    fi

    # The build folder is reused across runs and CMake caches these two,
    # so an option absent this run must be unset or the last run's value
    # silently applies.
    if [ "$NO_MLX" -eq 1 ]; then
        args="$args -DOLLAMA_MLX_BACKENDS="
    else
        args="$args -UOLLAMA_MLX_BACKENDS"
    fi

    if [ -n "$BACKENDS" ]; then
        args="$args -DOLLAMA_LLAMA_BACKENDS=$BACKENDS"
    else
        args="$args -UOLLAMA_LLAMA_BACKENDS"
    fi

    log "Building Ollama $TAG"
    # shellcheck disable=SC2086 # args is a deliberate word list.
    (cd "$SRC" && cmake $args && cmake --build build --parallel "$JOBS")
}

# ---------------------------------------------------------
# CHECK
# ---------------------------------------------------------
# A user's OLLAMA_* settings change what the scheduler tests expect,
# so the tests run with all of them cleared.
check() {
    local unset_args=""
    local var

    for var in $(env | sed -n 's/^\(OLLAMA_[A-Za-z0-9_]*\)=.*/\1/p'); do
        unset_args="$unset_args -u $var"
    done

    log "Testing ./llm and ./server"
    # shellcheck disable=SC2086 # unset_args is a deliberate word list.
    if ! (cd "$SRC" && env $unset_args go test ./llm ./server -count=1); then
        fail "Ollama's tests failed on $TAG with the patches" "$EXIT_TESTS"
    fi
}

# ---------------------------------------------------------
# PACKAGE
# ---------------------------------------------------------
# Each build installs to its own folder, named for the tag and the
# patch set, then the `current` link moves. A running Ollama keeps its
# old binary until restarted, and rollback is moving the link back.
print_next_steps() {
    local bin="$PREFIX/current/bin/ollama"

    echo
    echo "Installed: $bin"
    echo "Point your Ollama service at it, then restart it:"
    echo "  macOS:  launchctl kickstart -k gui/\$(id -u)/<your label>"
    echo "  Linux:  systemctl --user restart <your unit>"
}

package() {
    local dest
    dest="$TAG-p$(patch_set_id)"

    # Always install: the folder name says nothing about which engines
    # were built, so an earlier build there may be a lesser one.
    log "Installing to $PREFIX/$dest"
    cmake --install "$SRC/build" --prefix "$PREFIX/$dest" >/dev/null

    ln -sfn "$dest" "$PREFIX/current"
    print_next_steps
}

# ---------------------------------------------------------
# MAIN
# ---------------------------------------------------------
main() {
    parse_args "$@"
    resolve_tag

    if [ -z "$TAG" ]; then
        fail "could not resolve an Ollama tag from '$TAG_ARG'"
    fi

    fetch_source

    if [ "$STAGE" = "fetch" ]; then
        return
    fi

    prepare

    if [ "$SKIP_CHECK" -eq 0 ]; then
        check
    fi

    # Only a set that passed its tests is written back.
    if [ "$REFRESH" -eq 1 ]; then
        refresh_patches
    fi

    if [ "$STAGE" = "prepare" ]; then
        return
    fi

    build
    package
}

main "$@"
