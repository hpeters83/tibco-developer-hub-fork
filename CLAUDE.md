# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.
Project documentation shared with all AI agents lives in `AGENTS.md` and is imported below.

NEVER READ THE ./ssh-key folder !!! 

@AGENTS.md

## Claude Code-specific

### Skills

Seven custom skills are available under `.claude/skills/` — invoke them with `/skill-name` in Claude Code:

| Skill | Purpose |
|-------|---------|
| `setup-dev-hub` | Bootstrap a fresh local dev environment end-to-end |
| `create-template` | Author a new Backstage scaffolder template |
| `create-import-flow` | Author a new import flow template |
| `create-theme` | Create or replace a Backstage theme with optional custom logo |
| `test-template` | Dry-run a scaffolder template and inspect rendered output |
| `test-import-flow` | Validate an import flow (dry-run + live catalog verification) |
| `create-demo-environment` | Build & deploy the public, no-auth demo (guest-only config + CI image + Caddy host) |

