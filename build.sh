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

# ---------------------------------------------------------
# OPTIONS
# ---------------------------------------------------------
TAG_ARG="pinned"
PREFIX="$DEFAULT_PREFIX"
REFRESH=0
STAGE="all"
SKIP_CHECK=0
NO_MLX=0
BACKENDS=""
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# Set by the steps below.
TAG=""
SRC=""
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
    if [ "$TAG_ARG" = "pinned" ]; then
        TAG="$(tr -d '[:space:]' <"$PIN_FILE")"
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

    if [ ! -d "$SRC/.git" ]; then
        log "Fetching Ollama $TAG"
        mkdir -p "$SRC_ROOT"
        git -c advice.detachedHead=false clone -q --depth 1 \
            --branch "$TAG" "$UPSTREAM" "$SRC"
        return
    fi

    log "Reusing $SRC"
    git -C "$SRC" am --abort >/dev/null 2>&1 || true
    git -C "$SRC" reset -q --hard "refs/tags/$TAG"
    git -C "$SRC" clean -q -fd
}

# ---------------------------------------------------------
# PREPARE
# ---------------------------------------------------------
# Each patch either applies (three-way), is already upstream (it
# applies in reverse, so it is dropped), or conflicts. Conflicts are
# reported together; nothing is built from a partial patch set.
apply_patch() {
    local patch="$1"
    local name
    name="$(basename "$patch")"

    if git -C "$SRC" apply --check --reverse "$patch" >/dev/null 2>&1; then
        log "Already upstream, dropping: $name"
        DROPPED="$DROPPED $name"
        return
    fi

    if git -C "$SRC" -c user.name="$SCRATCH_NAME" \
        -c user.email="$SCRATCH_EMAIL" -c commit.gpgsign=false \
        am -q -3 "$patch" >/dev/null 2>&1; then
        log "Applied: $name"
        APPLIED="$APPLIED $name"
        return
    fi

    git -C "$SRC" am --abort >/dev/null 2>&1 || true
    log "Conflict: $name"
    CONFLICTED="$CONFLICTED $name"
}

write_summary() {
    local summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

    {
        echo "### $PKGNAME on Ollama $TAG"
        echo
        echo "- Applied:${APPLIED:- none}"
        echo "- Dropped (already upstream):${DROPPED:- none}"
        echo "- Conflicted:${CONFLICTED:- none}"
    } >>"$summary"
}

# Rewrites patches/ from the commits now on top of the tag, so the
# next release applies against fresh context. Dropped patches vanish
# because they produced no commit.
refresh_patches() {
    log "Refreshing patches against $TAG"
    rm -f "$PATCH_DIR"/*.patch
    git -C "$SRC" format-patch -q --zero-commit --no-signature \
        -o "$PATCH_DIR" "refs/tags/$TAG..HEAD"
    echo "$TAG" >"$PIN_FILE"
}

prepare() {
    local patch

    for patch in "$PATCH_DIR"/*.patch; do
        [ -e "$patch" ] || continue
        apply_patch "$patch"
    done

    write_summary

    if [ -n "$CONFLICTED" ]; then
        fail "patches do not apply to $TAG:$CONFLICTED" "$EXIT_CONFLICT"
    fi

    if [ "$REFRESH" -eq 1 ]; then
        refresh_patches
    fi
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

        if [ "$NO_MLX" -eq 0 ] && ! has_metal_toolchain; then
            log "No Metal Toolchain; building without MLX."
            log "Install it with: xcodebuild -downloadComponent MetalToolchain"
            NO_MLX=1
        fi
    fi

    if [ "$NO_MLX" -eq 1 ]; then
        args="$args -DOLLAMA_MLX_BACKENDS="
    fi

    if [ -n "$BACKENDS" ]; then
        args="$args -DOLLAMA_LLAMA_BACKENDS=$BACKENDS"
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

    if [ -d "$PREFIX/$dest" ]; then
        log "Already installed: $PREFIX/$dest"
    else
        log "Installing to $PREFIX/$dest"
        cmake --install "$SRC/build" --prefix "$PREFIX/$dest" >/dev/null
    fi

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

    if [ "$STAGE" = "prepare" ]; then
        return
    fi

    build
    package
}

main "$@"
