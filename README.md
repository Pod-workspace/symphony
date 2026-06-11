# Symphony

Fork of [openai/symphony](https://github.com/openai/symphony) with production-oriented defaults, tracker adapters, pluggable agent backends, and a complete onboarding flow. Put work in Linear or Notion, Symphony gives each item an isolated workspace and keeps an agent moving it toward a PR.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

## Quick start

Clone this repo, then ask your AI coding agent to use `.agents/skills/symphony-setup/SKILL.md` to set up Symphony for your repo.

```bash
git clone https://github.com/Pod-workspace/symphony
cd symphony
```

## How it works

Symphony polls a tracker for active work. Each issue or page gets an isolated workspace clone and an agent session. The agent reads the task, maintains a workpad, implements, validates, opens a PR, handles review loops, and keeps tracker state current.

The state machine lives in `WORKFLOW.md` — a markdown file with YAML frontmatter for config and a prompt body that defines agent behavior. The file reloads while Symphony is running, and the `make hot` run mode can also hot-recompile Elixir changes for long-lived nodes.

## What's different from upstream

- **Tracker adapters** — Linear remains the default, and Notion databases are also supported through schema-aware REST calls, managed `## Codex Workpad` sections, task state mapping, and dependency-aware dispatch.
- **Pluggable agents** — Codex is still the default agent backend, with a Claude Code adapter available through the same orchestration loop. Claude gets Symphony dynamic tools through the built-in MCP server.
- **Cheaper tracker calls** — agents no longer burn tokens on schema introspection before every Linear GraphQL call. Linear and Notion skills favor narrow reads, targeted writes, and the `sync_workpad` dynamic tool.
- **Correct sandbox** — the workflow is git + GitHub PR centric. Upstream's default sandbox blocks `.git/` writes, which silently breaks the entire flow. Fixed.
- **Operational dashboard** — the observability UI now runs on Phoenix LiveView, shows Codex account/plan details and normalized rate-limit status, and can bind to a custom host/port.
- **Long-lived run mode** — `make hot` keeps active agents running while workflow edits and most Elixir source changes reload.
- **More durable orchestration** — continuation retries back off instead of churning, blocker hydration survives revalidation, noisy streaming notifications are filtered, and closed or terminal work is cleaned up more reliably.
- **Media uploads via Linear** — upstream references a GitHub media upload skill that doesn't ship. The workflow and Linear skill now use Linear's native `fileUpload` mutation for screenshots and recordings.
- **Setup skill** — auto-detects your repo, installs worker skills, creates Linear workflow states, and verifies everything before launch.

## Manual setup

1. Build: `git clone https://github.com/Pod-workspace/symphony && cd symphony/elixir && mise trust && mise install && mise exec -- mix setup && mise exec -- mix build`
2. Copy worker skills from this checkout into your repo's `.agents/skills/` directory: `linear`, `notion`, `land`, `commit`, `push`, `pull`, and `debug`. Then copy `elixir/WORKFLOW.md` to your repo as `WORKFLOW.md`.
3. In `WORKFLOW.md`, set `tracker.kind`, tracker IDs, and `hooks.after_create` (clone your repo + setup commands). For Linear, set `tracker.kind: linear` and `tracker.project_slug`. For Notion, set `tracker.kind: notion` and `tracker.data_source_id`.
4. For Linear projects, add **Rework**, **Human Review**, **Merging** as custom states in Linear (Team Settings -> Workflow). For Notion, configure equivalent state names or map your existing statuses in the `tracker.notion` block.
5. Pick an agent backend. Use the default `agent.agent_adapter: codex`, or set `agent.agent_adapter: claude` and configure the `claude` block. Linear reads `LINEAR_API_KEY` by default; Notion reads `NOTION_API_KEY`; Claude reads `ANTHROPIC_API_KEY`.
6. Commit, push, then either
   `mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails /path/to/your-repo/WORKFLOW.md` or
   `cd elixir && mise exec -- make hot WORKFLOW=/path/to/your-repo/WORKFLOW.md`.
   Add `--port 4003 --host 0.0.0.0` to `./bin/symphony`, or `PORT=4003 HOST=0.0.0.0` to
   `make hot`, if the dashboard needs to be reachable off-host.

## License

[Apache License 2.0](LICENSE)
