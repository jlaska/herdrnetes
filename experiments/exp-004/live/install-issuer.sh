#!/bin/sh
# EXP-004 verified installer for the experimental credential issuer.
#   install-issuer.sh [--replace] <src-clone> <rev> <dest>
#   install-issuer.sh --print-manifest <exp004-dir>
# Run with `sh` from a root-owned fresh clone checked out (detached) at the reviewed full 40-hex commit.
# Installs ONLY the files listed in live/MANIFEST.sha256, from the committed blobs (git show), never from
# the working tree. Any failure: remove staging and anything this run created, exit non-zero.
set -eu
umask 077
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_PARAMETERS
LC_ALL=C; export LC_ALL

MPATHS="harness/issuer.py harness/issuer-ctl.py live/issuer-start.sh"
MREL=live/MANIFEST.sha256
BASE=experiments/exp-004

STAGE="" CREATED="" CREATED_DIRS="" BACKUPS="" DONE=0 DEST_CREATED=0 DEST=""

refuse() { echo "INSTALL REFUSED: $*" >&2; exit 1; }

cleanup() {
  rc=$?
  trap - EXIT
  if [ "$DONE" -ne 1 ]; then
    for f in $CREATED; do rm -f "$f" 2>/dev/null || :; done
    # restore files moved aside by --replace
    for b in $BACKUPS; do
      [ -f "$STAGE/backup/$b" ] && cp -p "$STAGE/backup/$b" "$DEST/$b" 2>/dev/null || :
    done
    for d in $CREATED_DIRS; do rmdir "$d" 2>/dev/null || :; done
    [ "$DEST_CREATED" -eq 1 ] && rmdir "$DEST" 2>/dev/null || :
    [ $rc -eq 0 ] && rc=1
  fi
  [ -n "$STAGE" ] && rm -rf "$STAGE"
  exit $rc
}

sha_of() { sha256sum | cut -d' ' -f1; }

if [ "${1:-}" = "--print-manifest" ]; then
  [ $# -eq 2 ] || { echo "usage: $0 --print-manifest <exp004-dir>" >&2; exit 2; }
  cd "$2"
  # shellcheck disable=SC2086 # fixed list of plain paths
  sha256sum $MPATHS
  exit 0
fi

REPLACE=0
if [ "${1:-}" = "--replace" ]; then REPLACE=1; shift; fi
[ $# -eq 3 ] || { echo "usage: $0 [--replace] <src-clone> <rev> <dest>" >&2; exit 2; }
SRC=$1 REV=$2 DEST=$3

trap cleanup EXIT

# ---- arguments ----
printf '%s\n' "$REV" | grep -Eq '^[0-9a-f]{40}$' || refuse "rev must be a full 40-hex commit id (got '$REV')"
case "$DEST" in /*) ;; *) refuse "dest must be an absolute path" ;; esac
case "$DEST" in *[!A-Za-z0-9._/+-]*) refuse "dest contains unsupported characters" ;; esac
[ -d "$SRC" ] || refuse "src '$SRC' is not a directory"
SRC=$(cd "$SRC" && pwd -P)
case "$SRC" in *[!A-Za-z0-9._/+-]*) refuse "src path contains unsupported characters" ;; esac
EXP=$SRC/$BASE
[ -d "$EXP" ] || refuse "$EXP missing"

# ---- git state ----
head=$(git -C "$SRC" rev-parse HEAD 2>/dev/null) || refuse "$SRC is not a git work tree"
[ "$head" = "$REV" ] || refuse "src HEAD ($head) != requested rev ($REV)"
dirty=$(git -C "$SRC" status --porcelain --untracked-files=no -- "$BASE" 2>&1) || refuse "git status failed"
[ -z "$dirty" ] || refuse "modified tracked files under $BASE: $(echo "$dirty" | tr '\n' ';')"

# ---- ownership (root only) ----
if [ "$(id -u)" -eq 0 ]; then
  bad_node() { find "$1" -maxdepth 0 \( ! -user root -o -perm -020 -o -perm -002 \) -print; }
  p=$SRC
  while :; do
    [ -z "$(bad_node "$p")" ] || refuse "$p is not root-owned or is group/world-writable"
    [ "$p" = / ] && break
    p=$(dirname "$p")
  done
  bad=$(find "$SRC" \( ! -user root -o \( ! -type l -a \( -perm -020 -o -perm -002 \) \) \) -print -quit)
  [ -z "$bad" ] || refuse "$bad is not root-owned or is group/world-writable"
  p=$(dirname "$DEST")
  while [ ! -e "$p" ]; do p=$(dirname "$p"); done
  while :; do
    [ -z "$(bad_node "$p")" ] || refuse "dest ancestor $p is not root-owned or is group/world-writable"
    [ "$p" = / ] && break
    p=$(dirname "$p")
  done
else
  echo "WARNING: not root: ownership checks skipped (test mode)"
fi

# ---- dest policy (before copying anything) ----
[ ! -L "$DEST" ] || refuse "dest is a symlink"
if [ -e "$DEST" ]; then
  [ -d "$DEST" ] || refuse "dest exists and is not a directory"
  if [ -n "$(ls -A "$DEST")" ] && [ "$REPLACE" -ne 1 ]; then
    refuse "dest $DEST exists and is non-empty (use --replace to replace manifest files only)"
  fi
fi

# ---- manifest: committed == working tree; syntax ----
MF=$EXP/$MREL
[ -f "$MF" ] && [ ! -L "$MF" ] || refuse "manifest missing or not a regular file"
mh=$(sha_of <"$MF")
ch=$(git -C "$SRC" show "$REV:$BASE/$MREL" 2>/dev/null | sha_of)
[ "$mh" = "$ch" ] || refuse "manifest differs from the one committed at $REV"
[ -s "$MF" ] || refuse "manifest empty"
if grep -Ev '^[0-9a-f]{64}  (harness|live)/[A-Za-z0-9_][A-Za-z0-9._-]*$' "$MF" | grep -q .; then
  refuse "manifest has a malformed line or a path outside harness/ and live/ (or with .., absolute path)"
fi
[ -z "$(cut -c67- "$MF" | sort | uniq -d)" ] || refuse "manifest lists a path twice"
(cd "$EXP" && sha256sum -c --strict --quiet "$MREL") || refuse "working-tree files do not match the manifest"

ENTRIES=$(cat "$MF")
while read -r h p; do
  [ -f "$EXP/$p" ] && [ ! -L "$EXP/$p" ] || refuse "$p is not a regular file in the working tree"
  g=$(git -C "$SRC" show "$REV:$BASE/$p" 2>/dev/null | sha_of)
  [ "$g" = "$h" ] || refuse "$p: committed blob at $REV does not match the manifest"
done <<EOF2
$ENTRIES
EOF2

# ---- stage from committed blobs, re-verify ----
PARENT=$(dirname "$DEST")
[ -d "$PARENT" ] || mkdir -p "$PARENT"
STAGE=$(mktemp -d "$PARENT/.exp004-stage.XXXXXX")
chmod 700 "$STAGE"
mkdir "$STAGE/files" "$STAGE/backup"
cp "$MF" "$STAGE/MANIFEST"
while read -r h p; do
  mkdir -p "$STAGE/files/$(dirname "$p")"
  git -C "$SRC" show "$REV:$BASE/$p" >"$STAGE/files/$p" || refuse "cannot read $p at $REV"
done <<EOF2
$ENTRIES
EOF2
(cd "$STAGE/files" && sha256sum -c --strict --quiet ../MANIFEST) || refuse "staged copies do not match the manifest"

# ---- install from staged copies ----
ROOT=0; [ "$(id -u)" -eq 0 ] && ROOT=1
mkd() {  # mkd <dir>: create 0755 dir if absent, tracking it
  if [ ! -d "$1" ]; then
    mkdir "$1"; chmod 755 "$1"
    [ "$ROOT" -eq 1 ] && chown root:root "$1"
    CREATED_DIRS="$1 $CREATED_DIRS"
  fi
}
if [ ! -d "$DEST" ]; then
  mkdir "$DEST"; DEST_CREATED=1; chmod 755 "$DEST"
  [ "$ROOT" -eq 1 ] && chown root:root "$DEST"
fi
while read -r h p; do
  mkd "$DEST/$(dirname "$p")"
  t=$DEST/$p
  if [ -e "$t" ]; then
    [ -f "$t" ] && [ ! -L "$t" ] || refuse "existing $t is not a regular file"
    mkdir -p "$STAGE/backup/$(dirname "$p")"
    cp -p "$t" "$STAGE/backup/$p"; BACKUPS="$p $BACKUPS"
  else
    CREATED="$t $CREATED"
  fi
  cp "$STAGE/files/$p" "$t.new.$$"
  case "$p" in *.py|*.sh) chmod 755 "$t.new.$$" ;; *) chmod 644 "$t.new.$$" ;; esac
  [ "$ROOT" -eq 1 ] && chown root:root "$t.new.$$"
  mv -f "$t.new.$$" "$t"
done <<EOF2
$ENTRIES
EOF2
(cd "$DEST" && sha256sum -c --strict --quiet "$STAGE/MANIFEST") || refuse "installed files do not match the manifest"

# report extras (only possible with --replace)
extras=$(cd "$DEST" && find . -type f | sed 's|^\./||' | sort | while read -r f; do
  grep -q "  $f\$" "$STAGE/MANIFEST" || echo "$f"; done)
DONE=1
echo "Installed $(wc -l <"$STAGE/MANIFEST" | tr -d ' ') files into $DEST"
[ -z "$extras" ] || echo "NOTE: files in dest NOT in the manifest were left untouched: $(echo "$extras" | tr '\n' ' ')"
echo "rev: $REV"
# shellcheck disable=SC2046 # manifest paths are validated plain names (no spaces or globs)
(cd "$DEST" && sha256sum $(cut -c67- "$STAGE/MANIFEST"))
echo "REMINDER: compare the rev and hashes above with those in the reviewed comment on GitHub, NOT with anything on the workstation."
