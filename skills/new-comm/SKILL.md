---
name: new-comm
description: Create a new Comment.io Comm from supplied context, a matching template, or another document. Use for `$new-comm` or `/new-comm` or when the user asks to make, draft, import, or convert content into a new Comm.
---

# Create a new Comm

Create and fill one readable Comm, then leave the user at its canonical link.

## 1. Establish the route and identity

Invoke the installed `comment` skill before any Comment.io action. Let it select
the exact origin, fetch live API guidance, and establish the conversation
identity. Then invoke `listen`; this request authorizes arming the same identity.
An unavailable listener does not block creation.

This step is complete when creation, editing, and listening use one origin and
one identity policy.

## 2. Resolve the source

- Read a supplied file, URL, prior Comm, or other source with an available
  native capability.
- Otherwise use supplied notes or prior context.
- With neither a source nor enough context to determine the Comm's purpose, ask
  what the user wants the Comm to be about.

Do not create a placeholder while required source material or purpose is
missing. This step is complete when the content and purpose are usable.

## 3. Choose the structure

Search available Comment.io templates with a broad, distinctive term for the
source's purpose. Compare plausible results by title, description, keywords,
and instructions.

When a supplied source has a strong template match, ask whether to rewrite it
to fit the template or import its visible content and structure unchanged.
For an unchanged import, preserve visible content and hierarchy and add native
instructions that guide future work in every section and nested subsection.

Otherwise use an obvious matching template without another confirmation. With
no strong match, create a blank Comm with native whole-document instructions,
the required headings, and native section instructions for every structural
section at every depth. Instructions are metadata, not body copy.

Immediately retain the exact human-openable URL returned by creation. Creation
is final at that point; recover later failures against that Comm instead of
creating another one.

## 4. Fill and hand off

Write from the resolved source and follow all document and section
instructions. Preserve meaning and requested detail. Mark unknowns instead of
guessing. Remove accidental empty sections. Turn material placeholders into
anchored comments that @mention the user with the exact decision or information
needed.

Leave listening armed, report its honest state, and leave the Comm unopened so
the user can open it. End the final response with the exact human-openable URL
on its own line; it must be the final line.
