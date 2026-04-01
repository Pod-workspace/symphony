---
name: notion
description: |
  Notion REST patterns for Symphony agents. Use `notion_api` for narrow page
  and data-source requests, property updates, relation lookups, and follow-up
  ticket creation, and use `sync_workpad` for managed workpad updates.
---

# Notion REST

All Notion tracker operations go through the `notion_api` and `sync_workpad`
tools exposed by Symphony's app server. Do not use a separate Notion MCP server
unless the workflow explicitly tells you to.

```json
{
  "method": "GET|POST|PATCH|PUT|DELETE",
  "path": "/pages/<page-id>",
  "query": { "optional": "query params" },
  "body": { "optional": "json body" }
}
```

One HTTP operation per tool call. A non-2xx response or top-level `error`
payload means the request failed.

## Schema-first writes

- Before the first tracker write in a session, fetch `GET /data_sources/<id>`.
- Confirm the exact property names and property types you are about to touch.
- Read property names, state names, and data source IDs from the current
  workflow or injected issue context. Do not hardcode another repo's schema.
- State properties may be `status` or `select`. Write the shape that matches the
  fetched schema.

## Narrow reads

Use the smallest request that answers the question:

- `GET /pages/<page-id>` for current page properties and relations
- `GET /pages/<page-id>/markdown` for page body or workpad recovery
- `POST /data_sources/<id>/query` for filtered lookups or follow-up searches

For branch context and blocker resolution, fetch the current page first, then
fetch only the directly related pages you need.

## Property updates

Patch only the properties you intend to change:

```json
{
  "method": "PATCH",
  "path": "/pages/<page-id>",
  "body": {
    "properties": {
      "<state-property>": { "status": { "name": "In Progress" } },
      "<pr-url-property>": { "url": "https://github.com/org/repo/pull/123" }
    }
  }
}
```

- If the fetched schema says the state field is `select`, use `select` instead
  of `status`.
- For URL properties, write `url`, not `rich_text`.
- For relation properties, write related page references, not human ticket keys.

## Follow-up ticket creation

Create new tickets with `POST /pages` and set `parent.data_source_id` to the
current tracker data source. Set only the required properties at creation time,
then patch additional relations or metadata if that keeps the write simpler.

After creating a follow-up page, fetch it again before linking it from another
page or handing control to another agent.

## Workpad

Maintain a local `workpad.md` in the workspace and sync it at milestones. Do
not resync after every small change.

Use `sync_workpad` as the primary path:

```json
{
  "issue_id": "<page-id>",
  "file_path": "workpad.md"
}
```

- `sync_workpad` keeps a single managed `## Codex Workpad` section on the page.
- If `sync_workpad` is unavailable, fall back to `GET /pages/<page-id>/markdown`
  and `PATCH /pages/<page-id>/markdown`, replacing only the managed workpad
  section.
- Do not use tracker comments for routine progress unless the workflow
  explicitly requires it.

## Rules

- Keep requests narrow and schema-aware.
- Keep writes to the same page serialized; do not let multiple agents update
  one Notion page concurrently.
- Prefer targeted property updates and workpad sync over rewriting the full page
  body unless the workflow explicitly says to.
- Fetch again after meaningful writes when later steps depend on the updated
  state.
