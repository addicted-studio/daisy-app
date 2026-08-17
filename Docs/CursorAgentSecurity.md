# Cursor Agent integration security decision

Status: **API-key mode only**.

Cursor's documented `--print` mode is not a tool-free completion API. It has
agent tools, including file operations and shell access, and the CLI may also
load user-scoped MCP configuration. Cursor currently documents no command-line
flag that removes every tool. Therefore Daisy must not describe this route as
fully sandboxed.

Daisy's boundary is:

- resolve only an executable whose basename is `cursor-agent`;
- invoke it directly, never through a shell;
- pass the transcript through stdin and an API key only through
  `CURSOR_API_KEY`;
- create a new empty `0700` working directory per request and remove it after
  completion;
- write a project-local `.cursor/cli.json` denying `Shell(*)`, all relative and
  absolute `Read`/`Write` patterns, and `Mcp(*:*)`;
- never pass `--force`;
- request the documented single-object JSON output and decode the nested answer
  through Daisy's shared `CloudSummaryDTO`;
- bound stdout/stderr, runtime, and cancellation;
- never return or log raw child diagnostics.

The prompt additionally treats the transcript as untrusted meeting data and
instructs the agent not to use tools. This is defense in depth, not the primary
permission boundary.

Daisy does not use Cursor account sessions or inspect Cursor credential files.
The only supported route passes a user-provided API key from Keychain through
`CURSOR_API_KEY`, which Cursor documents as its automation mechanism. This keeps
the connection explicit and avoids depending on undocumented account behavior.

References:

- https://docs.cursor.com/en/cli/reference/parameters
- https://docs.cursor.com/cli/reference/permissions
- https://docs.cursor.com/en/cli/reference/output-format
- https://docs.cursor.com/en/cli/reference/authentication
