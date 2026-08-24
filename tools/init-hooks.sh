#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# Initializes the repository by setting up the necessary Git hooks.
# This script is intended to be run once after cloning the template.

set -e

# Find the git repository root
GIT_DIR=$(git rev-parse --git-dir)
if [ -z "$GIT_DIR" ]; then
    echo "[ERROR] Not a git repository. Cannot set up hooks."
    exit 1
fi

HOOKS_DIR="$GIT_DIR/hooks"
TOOLS_DIR=$(git rev-parse --show-toplevel)/tools

# core.hooksPath OVERRIDES $GIT_DIR/hooks entirely -- git runs the hook from
# there and never looks here. Measured (#82): a shared hooks directory outside
# the repository held a STALE COPY of the signer, so every commit was signed by
# a version this repository had replaced two releases earlier, and nothing said
# so. Installing a symlink into $GIT_DIR/hooks would have had no effect at all.
#
# The two arrangements are mutually exclusive. Say so instead of installing
# something that will silently do nothing.
CONFIGURED_HOOKS_PATH=$(git config --get core.hooksPath || true)
if [ -n "$CONFIGURED_HOOKS_PATH" ]; then
    echo "[!] core.hooksPath is set to: $CONFIGURED_HOOKS_PATH"
    echo "    Git takes hooks from there and IGNORES $HOOKS_DIR."
    echo "    Installing here would silently do nothing."
    echo
    echo "    Pick one:"
    echo "      git config --unset core.hooksPath   # then re-run this script"
    echo "      ln -sf \"$TOOLS_DIR/git_hook_commit-msg.sh\" \\"
    echo "             \"$CONFIGURED_HOOKS_PATH/commit-msg\"   # symlink, not a copy"
    echo
    echo "    Verify either way with: bash tools/check-hook-provenance.sh"
    exit 1
fi

echo "--- Initializing Git hooks ---"

# Capture the current PATH from the environment where init-hooks.sh is executed
CURRENT_PATH="$PATH"

# Set up pre-commit hook for validation
PRE_COMMIT_HOOK="$HOOKS_DIR/pre-commit"
if [ -f "$PRE_COMMIT_HOOK" ]; then
    echo "[INFO] A pre-commit hook already exists. Backing it up to pre-commit.bak."
    mv "$PRE_COMMIT_HOOK" "$PRE_COMMIT_HOOK.bak"
fi
echo "  ✓ Done."

# Set up commit-msg hook for signing
COMMIT_MSG_HOOK="$HOOKS_DIR/commit-msg"
if [ -f "$COMMIT_MSG_HOOK" ]; then
    echo "[INFO] A commit-msg hook already exists. Backing it up to commit-msg.bak."
    mv "$COMMIT_MSG_HOOK" "$COMMIT_MSG_HOOK.bak"
fi
echo "[*] Symlinking commit-msg hook from tools directory..."
ln -s -f "../../tools/git_hook_commit-msg.sh" "$COMMIT_MSG_HOOK"
echo "  ✓ Done."

# post-rewrite: after a rebase the commit-msg hook does not re-run, so the block
# a commit carries is the one signed for its OLD tree. Measured (#81): every
# commit on a rebased branch stops verifying, not just some. Without this hook
# that surfaces in CI after opening a PR; with it, right after the rebase.
POST_REWRITE_HOOK="$HOOKS_DIR/post-rewrite"
if [ -f "$POST_REWRITE_HOOK" ] && [ ! -L "$POST_REWRITE_HOOK" ]; then
    echo "[INFO] A post-rewrite hook already exists. Backing it up to post-rewrite.bak."
    mv "$POST_REWRITE_HOOK" "$POST_REWRITE_HOOK.bak"
fi
echo "[*] Symlinking post-rewrite hook from tools directory..."
ln -s -f "../../tools/git_hook_post-rewrite.sh" "$POST_REWRITE_HOOK"
echo "  ✓ Done."

# A symlink cannot go stale, but a wrapper or a hand-placed copy can. Prove the
# hook now in effect is the one this repository ships, rather than assuming the
# install worked.
echo "[*] Verifying the hook actually in effect..."
if sh -c 'bash "$0/check-hook-provenance.sh"' "$TOOLS_DIR"; then
    echo "\nRepository initialization complete. Hooks are set up and verified."
else
    echo "\n[!] The hook in effect is NOT the signer this repository ships."
    echo "    See the output above. Commits made here would carry the wrong"
    echo "    provenance, or none."
    exit 1
fi
