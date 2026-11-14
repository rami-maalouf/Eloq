# eloq-mcp

An MCP server for Eloq: agents read and write a person's vocabulary (overused words, target words
and the links between them) and count what they said, through that person's Eloq account. Every
write is one of the server's own mutations, so an agent is refused exactly where the app is.

```sh
cd services/mcp && bun install
ELOQ_URL=https://<your eloq server> bun src/main.ts login   # once; the session is kept in ~/.config/eloq (0600)
```

Claude Code:

```sh
claude mcp add eloq -e ELOQ_URL=https://<your eloq server> -- bun /path/to/eloq/services/mcp/src/main.ts
```

| Tool | What it does |
| --- | --- |
| `search_terms`, `get_term`, `list_links` | read the library |
| `add_term`, `update_term`, `delete_term` | change words |
| `link_terms` | suggest a move from an overused word to a target (lands in the app's Inbox) |
| `set_link_status`, `update_link`, `delete_link` | accept, dismiss or edit moves |
| `record_transcript` | count overused and target words in something said or written; stores counts, never text |
| `get_stats` | counts per word since a day, and per 1,000 spoken words |

Tests run against a local server: `bun run backend:dev` at the repository root, then `bun test` here.
