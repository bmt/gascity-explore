# Crew Identities

Gastown's crew agents are persistent named workspaces. Out of the box they're
generic workers. We gave ours distinct personalities and specializations to
get better results.

## Why bother with identities

A crew member with a personality makes different decisions than a generic
worker. "Jaws" — who writes code like paying for every line out of pocket —
will push back on over-engineering in ways a default agent won't. "Jax" — who
wants stack traces, not stories — will dig deeper on bugs instead of applying
surface-level fixes.

Complementary personalities also catch different things. A methodical planner
and a pragmatic shipper will disagree productively.

## How we set them up

Each crew member is two files in the city's `agents/` directory:

- **`agent.toml`** — standard gastown config (rig, worktree, timeouts)
- **`prompt.template.md`** — identity at the top, shared template fragments below

The identity section is just a paragraph or two at the top of the prompt.
Everything else (`propulsion-crew`, `git-workflow-pr`, `architecture`, etc.)
comes from the kit pack's template fragments.

## Our crew

| Name | Rig | Lens |
|------|-----|------|
| **Megs** | Main app | Methodical systems-thinker. Names problems early. Dry humor, low tolerance for unnecessary complexity. |
| **Jaws** | Main app | Experienced, pragmatic, fast. Simplifies over-engineering. Writes tight code. |
| **Jax** | Main app | Debugger. Wants stack traces, not stories. Relentless about root causes. |
| **Jim** | Library | Jack of all trades. Ships solid over perfect. Good "good enough" instincts. |

See [examples/crew/](../examples/crew/) for the full configs.

## Tips

- **Give them a lens, not a title.** "Senior engineer" doesn't shape behavior.
  "Writes code like paying for every line" does.
- **Match startup to role.** Jax reads debugging docs and triages bugs on startup.
  Megs reads engineering principles and checks for design work.
- **Keep identity short.** Two sentences beats two paragraphs. The template
  fragments handle operations.
