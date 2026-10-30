#!/usr/bin/env bash
# prepare-source.sh - lay out an Apple-enabled CS8409 codec source tree.
#
# The Apple code is not a standalone module: it is the in-tree
# snd-hda-codec-cs8409 driver with extra codec/amplifier initialisation.
# We therefore copy the kernel's own sound/hda sources, drop in the Apple
# headers, apply two small patches and build the result out-of-tree against
# the installed kernel headers.
#
# Usage:
#   scripts/prepare-source.sh --kernel 7.0.0-28-generic --dest /tmp/build
#
# Options:
#   -k, --kernel VER   kernel release (default: uname -r)
#   -d, --dest DIR     directory that will receive hda/ (default: ./build)
#   -s, --source DIR   use DIR/sound/hda from an already extracted kernel tree
#       --download     allow downloading the kernel tarball if no local
#                      kernel source is installed (off by default)
#       --no-download  never download (default)
#   -h, --help
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

KVER=""
DEST=""
SOURCE_TREE=""
ALLOW_DOWNLOAD=0

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while (($#)); do
    case "$1" in
        -k|--kernel) KVER=${2:?}; shift 2 ;;
        -d|--dest)   DEST=${2:?}; shift 2 ;;
        -s|--source) SOURCE_TREE=${2:?}; shift 2 ;;
        --download)  ALLOW_DOWNLOAD=1; shift ;;
        --no-download) ALLOW_DOWNLOAD=0; shift ;;
        -h|--help)   usage ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

KVER=${KVER:-$(uname -r)}
DEST=${DEST:-$REPO_DIR/build}
BASE=${KVER%%-*}                 # 7.0.0-28-generic -> 7.0.0

# Kbuild resolves M= against the kernel build directory, so every path we hand
# to it must be absolute.
mkdir -p "$DEST" || die "cannot create build directory $DEST"
DEST=$(cd -- "$DEST" && pwd)
if [[ -n $SOURCE_TREE ]]; then
    [[ -d $SOURCE_TREE ]] || die "source tree $SOURCE_TREE does not exist"
    # -P: resolve symlinks, otherwise cp -a would recreate the symlink and we
    # would end up patching the user's source tree in place.
    SOURCE_TREE=$(cd -- "$SOURCE_TREE" && pwd -P)
fi
HEADERS=/lib/modules/$KVER/build

# ---------------------------------------------------------------------------
# sanity checks
# ---------------------------------------------------------------------------
[[ -d $HEADERS ]] || die "kernel headers for $KVER not found.
  Ubuntu/Debian: sudo apt install linux-headers-$KVER
  Fedora:        sudo dnf install kernel-devel
  Arch:          sudo pacman -S linux-headers"

major=${BASE%%.*}
rest=${BASE#*.}
minor=${rest%%.*}
if (( major < 6 || (major == 6 && minor < 17) )); then
    die "kernel $KVER is too old. This package targets the sound/hda layout
  introduced in Linux 6.17. Older kernels need the pre-6.17 driver."
fi

if [[ ! -e $HEADERS/include/config/auto.conf ]]; then
    die "kernel $KVER headers are incomplete (no include/config/auto.conf).
  Install the matching linux-headers package."
fi

# ---------------------------------------------------------------------------
# locate sound/hda
# ---------------------------------------------------------------------------
extract_from_tarball() {
    local tarball=$1 tmp=$2
    info "extracting sound/hda from $(basename "$tarball")"
    rm -rf "$tmp"; mkdir -p "$tmp"
    # Every kernel source tarball puts the tree at <top>/sound/hda, so
    # stripping two components leaves exactly hda/.
    tar -xf "$tarball" -C "$tmp" --strip-components=2 --wildcards '*/sound/hda' 2>/dev/null \
        || die "could not extract sound/hda from $tarball (archive layout not understood)"
    [[ -f $tmp/hda/codecs/cirrus/cs8409.c ]] \
        || die "extracted archive did not contain the CS8409 driver source"
}

# A usable tree must contain the driver we are patching. Header packages also
# ship a sound/hda directory, but without any .c files - guard against that.
is_source_tree() {
    [[ -f $1/sound/hda/codecs/cirrus/cs8409.c ]]
}

mkdir -p "$DEST"
WORK_TMP=$DEST/.hda-extract
rm -rf "$DEST/hda" "$WORK_TMP"

FOUND=0

# 1. an explicitly supplied, already extracted kernel tree
if [[ -n $SOURCE_TREE ]]; then
    is_source_tree "$SOURCE_TREE" || die "$SOURCE_TREE/sound/hda/codecs/cirrus/cs8409.c does not exist"
    info "using kernel tree $SOURCE_TREE"
    cp -a "$SOURCE_TREE/sound/hda" "$DEST/hda"
    FOUND=1
fi

# 2. an extracted linux-source directory (Ubuntu/Debian)
if (( ! FOUND )); then
    for cand in "/usr/src/linux-source-$BASE" "/usr/src/linux-$BASE" \
                "/usr/src/kernels/$KVER" "/lib/modules/$KVER/source" \
                "/lib/modules/$KVER/build" "/usr/lib/modules/$KVER/build"; do
        if is_source_tree "$cand"; then
            info "using kernel source $cand/sound/hda"
            cp -a "$cand/sound/hda" "$DEST/hda"
            FOUND=1
            break
        fi
    done
fi

# 3. a source tarball already on disk
if (( ! FOUND )); then
    for tarball in "/usr/src/linux-source-$BASE.tar.bz2" \
                   "/usr/src/linux-source-$BASE.tar.xz" \
                   "/usr/src/linux-source-$BASE/linux-source-$BASE.tar.bz2" \
                   "/usr/src/linux-$BASE.tar.xz" \
                   "/usr/src/linux-$BASE.tar.bz2" \
                   "$REPO_DIR/.cache/linux-$BASE.tar.xz" \
                   "$REPO_DIR/.cache/linux-$BASE.tar.bz2"; do
        if [[ -f $tarball ]]; then
            extract_from_tarball "$tarball" "$WORK_TMP"
            mv "$WORK_TMP/hda" "$DEST/hda"
            rm -rf "$WORK_TMP"
            FOUND=1
            break
        fi
    done
fi

# 4. optional network download (opt-in: it is a ~150 MB file)
if (( ! FOUND )); then
    if (( ALLOW_DOWNLOAD )); then
        mkdir -p "$REPO_DIR/.cache"
        tarball="$REPO_DIR/.cache/linux-$BASE.tar.xz"
        url="https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-$BASE.tar.xz"
        info "downloading $url"
        if command -v curl >/dev/null; then
            curl -L --fail --progress-bar -o "$tarball.part" "$url" \
                && mv "$tarball.part" "$tarball"
        elif command -v wget >/dev/null; then
            wget -O "$tarball.part" "$url" && mv "$tarball.part" "$tarball"
        else
            die "neither curl nor wget is installed"
        fi
        extract_from_tarball "$tarball" "$WORK_TMP"
        mv "$WORK_TMP/hda" "$DEST/hda"
        rm -rf "$WORK_TMP"
        FOUND=1
    fi
fi

(( FOUND )) || die "kernel source for $BASE not found.
  Ubuntu/Debian: sudo apt install linux-source-$BASE
  Fedora:        sudo dnf install kernel-devel
  Arch:          install linux-source or run with --source /path/to/linux

  The kernel *headers* alone are not enough: this driver reuses the
  kernel's sound/hda helper sources and needs the corresponding source."

ok "source tree ready at $DEST/hda"

# ---------------------------------------------------------------------------
# graft the Apple driver onto the kernel source
# ---------------------------------------------------------------------------
info "installing build makefiles"
cp "$REPO_DIR/src/makefiles/Makefile"        "$DEST/hda/Makefile"
cp "$REPO_DIR/src/makefiles/Makefile_common" "$DEST/hda/common/Makefile"
cp "$REPO_DIR/src/makefiles/Makefile_codecs" "$DEST/hda/codecs/Makefile"
cp "$REPO_DIR/src/makefiles/Makefile_cirrus" "$DEST/hda/codecs/cirrus/Makefile"

info "installing Apple codec/amplifier code"
cp "$REPO_DIR"/src/apple/*.h "$DEST/hda/codecs/cirrus/"

info "patching cs8409.c and cs8409.h"
(
    cd "$DEST/hda"
    patch -p1 --forward --fuzz=3 --no-backup-if-mismatch \
        < "$REPO_DIR/src/patches/patch_cs8409.c.diff" >/dev/null
    patch -p1 --forward --fuzz=3 --no-backup-if-mismatch \
        < "$REPO_DIR/src/patches/patch_cs8409.h.diff" >/dev/null
) || die "the CS8409 patches did not apply. Your kernel's sound/hda sources
  differ too much from the ones this release was tested with ($BASE).
  Please open an issue with the output of: uname -r"

grep -q 'cirrus_apple.h' "$DEST/hda/codecs/cirrus/cs8409.c" \
    || die "internal error: Apple patch did not take effect"
ok "patched"

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------
KCFLAGS="-DAPPLE_PINSENSE_FIXUP -DAPPLE_CODECS -DCONFIG_SND_HDA_RECONFIG=1 -Wno-unused-variable -Wno-unused-function"

info "building snd-hda-codec-cs8409.ko for $KVER"
make -C "$HEADERS" M="$DEST/hda" CFLAGS_MODULE="$KCFLAGS" -j"$(nproc)" modules

KO=$DEST/hda/codecs/cirrus/snd-hda-codec-cs8409.ko
[[ -f $KO ]] || die "build finished but $KO was not produced"
ok "built $KO"
printf '%s\n' "$KO"
