---
name: new-comm
description: Create a new Comment.io Comm from supplied context, a matching template, or another document. Use for `$new-comm` or `/new-comm` or when the user asks to make, draft, import, or convert content into a new Comm.
---

# Create a new Comm

Create and fill one readable Comm, then leave the user at its canonical link.

## 1. Get the purpose

Use the supplied source, notes, or prior context to identify what the Comm
should help its readers understand, decide, or produce. With neither a source
nor enough context to determine that purpose, immediately ask:

> What should this Comm help its readers understand, decide, or produce?

Wait for the answer before invoking `how-to-use-comment` or `listen`. When a source is
already supplied, continue without asking; read it after establishing any
access route it requires and infer its purpose from the content.

This step is complete when the purpose is supplied or a source is available
from which to infer it.

## 2. Establish the route and identity

Invoke the installed `how-to-use-comment` skill before any Comment.io action. Then invoke
`listen`; this request authorizes arming the same identity. An unavailable
listener does not block creation.

This step is complete when creation, editing, and listening use one origin and
one identity policy.

## 3. Resolve the source

- Read a supplied file, URL, prior Comm, or other source with an available
  native capability.
- Otherwise use supplied notes or prior context.
- Confirm the purpose identified or inferred in step 1 against the resolved
  source.

This step is complete when the content and purpose are usable.

## 4. Create one Comm

Call `create_comm` now with `markdown` set to the requested content and
`agent_token` from this conversation's mint. When the user asked for a
template, use `list_templates` then `get_template` then `create_from_template`
with the same `agent_token`. Keep the human-openable URL from that one creation.

Immediately retain the exact human-openable URL returned by creation. Creation
is final at that point; recover later failures against that Comm instead of
creating another one.

## 5. Fill and hand off

Write from the resolved source and follow all document and section
instructions. Preserve meaning and requested detail. Mark unknowns instead of
guessing. Remove accidental empty sections. Turn material placeholders into
anchored comments that @mention the user with the exact decision or information
needed.

Leave listening armed, report its honest state, and leave the Comm unopened so
the user can open it. End the final response with the exact human-openable URL
on its own line; it must be the final line.
