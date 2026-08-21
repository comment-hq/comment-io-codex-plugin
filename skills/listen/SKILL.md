---
name: listen
description: Attach this exact local Codex conversation to Comment.io notifications. Use for `$listen`, “listen for mentions”, or “stop listening”, status, takeover, or stop. Default to the conversation's Ephemeral handle; use a durable handle only when the user explicitly selects it.
---

# Listen for Comment.io

The runtime is this plugin's `runtime/comment-plugin` file. It is not on PATH.
Never run a bare `comment-plugin` command. From this skill's path, replace
`/skills/listen/SKILL.md` with `/runtime/comment-plugin` and invoke that file.

Listen does not mint an identity. The connected Comment.io tools mint it.

If the user asked to stop or status, resolve the origin as in step 1, then
run step 6 or 5. Do not mint first.

Call `create_ephemeral_agent` immediately (the host may prefix the name).
Never inspect ALL_TOOLS or print tool descriptions. Never call `list_agents`.
If that call is available, those tools are logged in. If this skill loaded
and that call is unavailable, this plugin is installed and
the tools are not logged in: ask the user to connect the production Comment.io
tools already listed in this host, complete browser login, and retry listen in
a new chat. If the user asked to listen and this
skill is not available, the plugin is not installed. Do not search the repo.
Do not inspect plugin state.
Do not run `identity` or `listen bind` as a substitute.

1. Resolve the exact production HTTPS origin as the `comment` skill does. With
   no target context, use `https://comment.io`.
2. Call `create_ephemeral_agent` now with no arguments. Omit `idempotency_key`
   and mint once. Keep the returned `data` object in this conversation. A saved
   Durable Agent Token skips this mint. Do not reread skills from disk.
3. Adopt by writing that mint `data` object as one JSON line on stdin (never
   argv). Extra keys are fine. Do not rebuild fields. Durable adopt uses a
   `dat_` token and omits grant fields.
   Start exactly `<runtime> listen adopt --origin "$BASE"` with stdin open. Do not wrap it in `read`, `printf`, a pipe, a fifo, or a temp file. Write that JSON line to the process stdin, then close stdin.
   Wait until the command prints `ADOPTED`. Adopt is its own command. Do not
   chain `listen bind` onto it with `;` or `&&`.
4. After `ADOPTED`, run `<runtime> listen bind --origin "$BASE"` as a new
   command. Wait until it prints `ARMED @handle`. That is this conversation's
   Ephemeral identity. Then say `Connected as @handle` and stop. Do not mint
   again. Do not run status unless asked.
5. For status, run `<runtime> listen status --origin "$BASE"`. If it is
   armed, say `Connected as @handle`.
6. For stop, run `<runtime> listen stop --origin "$BASE"`. Removal of the
   local bind happens before the generation-fenced remote stop so takeover can
   never strand the handle.

When woken, call `receive` with `agent_token` set to the Agent Token from `create_ephemeral_agent` or a saved Durable Agent Token. It returns the work item and the current comm.
Then `reply_to_comment` or `edit_comm` with the same `agent_token` — those settle the work item.
The host lifecycle re-arms listening.

Speak like a chat status. Use the comm title and the link the tool returns.
Examples:
- Connected as @maxx.e-4d836ee0
- Replied on Testing notifications
  https://comment.io/d/ca0eab1d486055703b687e8af2e09023e?focus=comment-51f2ce2d-9aaf-46b1-8f6b-ee2942d69b93
- Edited Testing notifications
  https://comment.io/d/ca0eab1d486055703b687e8af2e09023e
- Didn't make changes in the Comm
- All done

After a reply or edit, print that status and close with `All done`.

Codex listening is a detached waiter for this thread on the shared app-server. Bind arms wake then returns; the waiter must outlive that command. If bind yields a session before ARMED, wait on that same session. Injection uses the idle app-server thread and does not require the bind process to remain the owned terminal. The waiter exits on explicit stop, SessionEnd, or app-server socket loss.
