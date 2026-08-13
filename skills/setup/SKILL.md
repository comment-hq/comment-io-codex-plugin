---
name: setup
description: Connect this local Codex plugin to Comment.io through browser approval. Use when the user asks to set up, connect, pair, configure, or repair the Comment.io plugin.
---

# Set up Comment.io

Use the installed plugin runtime at ``${PLUGIN_ROOT}/runtime/comment-plugin``. It owns credentials and
prints only safe status or browser-handoff values.

1. Resolve the Comment.io origin from a supplied Comm after its shortlink
   redirect, otherwise use `https://comment.io`. Accept only the exact final
   HTTPS origin.
2. Run `comment-plugin setup finish --origin "$BASE"`. If it reports `READY`,
   setup is complete.
3. If it reports `NOT_STARTED`, run `comment-plugin setup start --origin
   "$BASE"`. Give the user the one printed approval link, then stop. Do not hold
   the turn open while they approve it.
4. On the user's next turn, run `setup finish` again. A pending approval stays
   pending; an approved exchange atomically installs its owner-private key.

Never ask the user to paste a key. Never read, print, or copy plugin state.
For repair, repeat `setup finish`; start a new exchange only after the runtime
reports that the old one expired or is absent.
