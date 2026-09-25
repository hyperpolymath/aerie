#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# propagate-github-templates.sh — roll the canonical GitHub issue forms
# (and optionally the repo check-suite files) out across an estate as
# per-repo pull requests.
#
# Default owners: hyperpolymath (user account) and metadatastician (org).
#
#   ./scripts/propagate-github-templates.sh --dry-run          # survey only
#   ./scripts/propagate-github-templates.sh --only aerie       # single repo
#   ./scripts/propagate-github-templates.sh --apply            # raise the PRs
#
# Repos that do NOT carry their own .github/ISSUE_TEMPLATE are skipped by
# default: they inherit the estate defaults from the owner's .github repo
# (see docs/ESTATE-PROPAGATION.adoc, layer A). Pass --all to also raise
# PRs on those (making the forms explicit + frozen in-repo).
#
# Template placeholders {{FORGE}}, {{OWNER}}, {{REPO}} found in the copied
# files are substituted per target repo (FORGE defaults to github.com).
#
# Prereqs: gh (authenticated), git. Safe to re-run: an existing open PR
# branch is force-refreshed rather than duplicated.

set -euo pipefail

OWNERS="${ESTATE_OWNERS:-hyperpolymath metadatastician}"
TEMPLATE_DIR="${TEMPLATE_DIR:-$(cd "$(dirname "$0")/.." && pwd)/.github/ISSUE_TEMPLATE}"
SUPPORT_FILE="${SUPPORT_FILE:-}"         # optional .github/SUPPORT.md source
FORGE="${FORGE:-github.com}"
BRANCH="chore/sync-issue-forms"
APPLY=0; DRYRUN=0; ALL=0
ONLY=""
SKIP_FORKS=1; SKIP_ARCHIVED=1

usage() { sed -n '2,28p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --owners)        OWNERS="$2"; shift 2 ;;
    --templates)     TEMPLATE_DIR="$2"; shift 2 ;;
    --support-file)  SUPPORT_FILE="$2"; shift 2 ;;
    --forge)         FORGE="$2"; shift 2 ;;
    --only)          ONLY="$2"; shift 2 ;;
    --apply)         APPLY=1; shift ;;
    --dry-run)       DRYRUN=1; shift ;;
    --all)           ALL=1; shift ;;
    --include-forks) SKIP_FORKS=0; shift ;;
    --include-archived) SKIP_ARCHIVED=0; shift ;;
    -h|--help)       usage 0 ;;
    *) echo "unknown flag: $1" >&2; usage 1 ;;
  esac
done

command -v gh  >/dev/null 2>&1 || { echo "ERROR: gh CLI required"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git required"; exit 1; }
[ -d "$TEMPLATE_DIR" ] || { echo "ERROR: template dir not found: $TEMPLATE_DIR"; exit 1; }
if [ "$APPLY" -eq 0 ] && [ "$DRYRUN" -eq 0 ]; then
  echo "(neither --apply nor --dry-run: defaulting to --dry-run)"
  DRYRUN=1
fi

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

list_repos() { # owner -> tab-separated full_name, archived, fork
  local owner="$1" kind
  kind="$(gh api "users/$owner" --jq '.type' 2>/dev/null || echo User)"
  if [ "$kind" = "Organization" ]; then
    gh api --paginate "orgs/$owner/repos?per_page=100" \
      --jq '.[] | [.full_name, .archived, .fork] | @tsv'
  else
    gh api --paginate "users/$owner/repos?per_page=100" \
      --jq '.[] | [.full_name, .archived, .fork] | @tsv'
  fi
}

has_own_templates() { # owner/repo -> 0/1 via HTTP code of contents lookup
  gh api "repos/$1/contents/.github/ISSUE_TEMPLATE" >/dev/null 2>&1
}

render_into() { # src_file dest_file owner repo
  sed -e "s/{{FORGE}}/$FORGE/g" -e "s/{{OWNER}}/$3/g" -e "s/{{REPO}}/$4/g" "$1" > "$2"
}

row() { printf '%-55s %s\n' "$1" "$2"; }

echo "═══════════════════════════════════════════════════"
echo "  Estate template propagation"
echo "  owners:  $OWNERS"
echo "  source:  $TEMPLATE_DIR"
echo "  mode:    $([ "$APPLY" -eq 1 ] && echo APPLY || echo DRY-RUN)$([ "$ALL" -eq 1 ] && echo ' (all repos)')"
echo "═══════════════════════════════════════════════════"

for OWNER in $OWNERS; do
  echo ""
  echo "## $OWNER"
  while IFS=$'\t' read -r FULL ARCHIVED FORK; do
    NAME="${FULL#*/}"
    [ -n "$ONLY" ] && [ "$NAME" != "$ONLY" ] && continue
    if [ "$SKIP_ARCHIVED" -eq 1 ] && [ "$ARCHIVED" = "true" ];  then row "$FULL" "skip (archived)";  continue; fi
    if [ "$SKIP_FORKS" -eq 1 ]    && [ "$FORK" = "true" ];      then row "$FULL" "skip (fork)";      continue; fi
    if [ "$NAME" = ".github" ]; then
      row "$FULL" "skip (.github repo — handled by layer A of docs/ESTATE-PROPAGATION.adoc)"; continue
    fi

    if has_own_templates "$FULL"; then
      NEED="has own templates — PR"
    else
      if [ "$ALL" -eq 1 ]; then NEED="no own templates — PR (--all)"; else row "$FULL" "ok (inherits estate defaults)"; continue; fi
    fi

    if [ "$APPLY" -eq 0 ]; then row "$FULL" "would PR: $NEED"; continue; fi

    WT="$TMPROOT/${OWNER}-${NAME}"
    if ! git clone --depth 1 "https://github.com/$FULL" "$WT" >/dev/null 2>&1; then
      row "$FULL" "ERROR: clone failed (permissions?)"; continue
    fi
    (
      cd "$WT"
      git checkout -B "$BRANCH" >/dev/null 2>&1
      mkdir -p .github/ISSUE_TEMPLATE
      for f in "$TEMPLATE_DIR"/*; do
        render_into "$f" ".github/ISSUE_TEMPLATE/$(basename "$f")" "$OWNER" "$NAME"
      done
      if [ -n "$SUPPORT_FILE" ] && [ -f "$SUPPORT_FILE" ]; then
        render_into "$SUPPORT_FILE" ".github/SUPPORT.md" "$OWNER" "$NAME"
      fi
      git add .github
      if git diff --cached --quiet; then
        echo "$FULL — templates already identical"
        exit 3
      fi
      git -c user.email="${GIT_AUTHOR_EMAIL:-arena-bot@users.noreply.github.com}" \
          -c user.name="${GIT_AUTHOR_NAME:-estate-bot}" \
          commit -q -m "chore(github): sync issue forms (optional, consistent fields)

Source: hyperpolymath/aerie .github/ISSUE_TEMPLATE (issues #91/#92 class:
fields were inconsistently typed/required). Placeholders rendered for
$FULL. See docs/ESTATE-PROPAGATION.adoc." -m "Signed-off-by: ${GIT_AUTHOR_NAME:-estate-bot} <${GIT_AUTHOR_EMAIL:-arena-bot@users.noreply.github.com}>"
      git push -q --force-with-lease -u origin "$BRANCH"
      gh pr create --repo "$FULL" --title "chore(github): sync issue forms (optional, consistent fields)" \
        --base "$(gh repo view "$FULL" --json defaultBranchRef --jq .defaultBranchRef.name)" \
        --body $'## What\n\nSyncs the canonical issue forms from `hyperpolymath/aerie`:\n\n- All free-text fields are the same entry type (plain `textarea`; the `render: shell` split is gone).\n- No content field is mandatory — the only required items are the two attestation checkboxes on the bug form.\n- `{{FORGE}}`/`{{OWNER}}`/`{{REPO}}` placeholders were rendered for this repo.\n\n## Why\n\nTemplate-wide fix class (aerie issues #91/#92): reporters could not skip irrelevant fields, and one field rendered differently from its neighbours. See `docs/ESTATE-PROPAGATION.adoc` in aerie for the estate rollout plan.\n\nGenerated by `scripts/propagate-github-templates.sh`.' \
        2>&1 | tail -1
      # best-effort label; the repo may not define it
      gh pr edit --repo "$FULL" --add-label conformance >/dev/null 2>&1 || true
    ) || {
      rc=$?
      if [ "$rc" -eq 3 ]; then row "$FULL" "up to date"; else row "$FULL" "ERROR: PR step failed ($rc)"; fi
      continue
    }
    row "$FULL" "PR raised"
  done < <(list_repos "$OWNER")
done

echo ""
echo "Done. Next: verify checks are SCHEDULING (not startup-failing) on each PR —"
echo "see the verification sweep in docs/ESTATE-PROPAGATION.adoc §5."
