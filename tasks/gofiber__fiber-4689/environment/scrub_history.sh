#!/bin/sh
# Finish the git history scrub in a pr_runtime image, then prove nothing past `base` is left.
#
# Repo2RLEnv (main 61903fe) clones with --filter=blob:none. Its scrub prunes branches, tags and
# reflogs, but leaves ORIG_HEAD/FETCH_HEAD and the promisor pack, which gc never prunes. In our
# images `git show ORIG_HEAD:<file>` printed the fixed source and the hidden tests, offline.
# The repack step is the one in huggingface/Repo2RLEnv#247 (for #235); drop this script once
# that is merged and the gen pin is bumped. Runs before the verifier copies /workspace.
set -eu
cd /workspace
G=$(git rev-parse --git-dir)
git rev-parse -q --verify refs/heads/base >/dev/null
rm -f "$G/ORIG_HEAD" "$G/FETCH_HEAD" "$G/MERGE_HEAD" "$G/CHERRY_PICK_HEAD" "$G/REVERT_HEAD" "$G/AUTO_MERGE"
git for-each-ref --format='%(refname)' | grep -vx refs/heads/base | xargs -r -n1 git update-ref -d
git reflog expire --expire=now --all
P="$G/objects/pack"
if ls "$P"/*.promisor >/dev/null 2>&1; then
  git rev-list --objects --all --missing=allow-promisor > "$G/scrub.list"
  K=$(git pack-objects -q --missing=allow-promisor "$P/scrub" < "$G/scrub.list")
  rm -f "$G/scrub.list" "$P"/pack-* "$P"/multi-pack-index*
  touch "$P/scrub-$K.promisor"
fi
git prune --expire=now
git gc -q --prune=now
# Fail the build if anything beyond `base` survived.
test "$(git for-each-ref --format='%(refname)')" = refs/heads/base
for f in ORIG_HEAD FETCH_HEAD MERGE_HEAD; do test ! -e "$G/$f"; done
reach=$(git rev-list --all | wc -l)
have=$(git cat-file --batch-all-objects --batch-check='%(objecttype)' | grep -cx commit)
test "$have" -eq "$reach"
test -z "$(git fsck --unreachable --no-reflogs --no-progress 2>/dev/null | grep '^unreachable')"
test -z "$(git status --porcelain --untracked-files=no)"
echo "scrub ok: $have commit(s), HEAD $(git rev-parse --short HEAD)"
