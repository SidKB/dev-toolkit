# dev-toolkit

A Claude Code plugin that gives every session the same guardrails, code
checks, notifications and context, so Claude works to the same standard in
every project.

**Platforms:** macOS and Linux. Windows isn't supported.

**Contents:**
[Quick start](#quick-start) ·
[What you get](#what-you-get) ·
[Settings](#settings) ·
[Hooks](#hooks) ·
[Good to know](#good-to-know) ·
[Adding to the toolkit](#adding-to-the-toolkit)

---

## Quick start

1. **Install the plugin** (in Claude Code):
   ```
   /plugin marketplace add /Users/siddharthabehera/Documents/CODE/claude
   /plugin install dev-toolkit@local-plugins
   ```
2. **Install the tools** (in a terminal). `jq` ships with macOS.
   ```
   brew install jq google-java-format checkstyle pmd yamllint
   ```
3. **Install the protected-file rules** (in a terminal, once):
   ```
   scripts/guards/sync-deny-rules.sh --install
   ```

After changing the plugin, bump `version` in `.claude-plugin/plugin.json` and
reinstall.

---

## What you get

| Area | What it does for you |
|---|---|
| 🛡️ **Safety** | Blocks destructive commands, asks before deleting folders, keeps Claude away from `.env` and key files, stops changes to installed plugins, and undoes unsafe settings changes. |
| ✅ **Code quality** | Formats and checks Java (google-java-format, Checkstyle, PMD), JSON and YAML after every edit. Problems go straight back to Claude to fix. |
| 🧠 **Context** | After the conversation is compacted, puts your own messages back word for word, so Claude keeps your decisions. |
| 🔔 **Notifications** | Desktop notification when Claude needs you, or when a task over 5 minutes finishes. |
| 📜 **Audit trail** | Logs every command Claude runs and every file it changes, with secrets masked. |

Also included: the `memory` MCP server (`@modelcontextprotocol/server-memory`).

---

## Settings

Open `/config` → **dev-toolkit**. All are on by default.

| Setting | What it controls |
|---|---|
| **Restore context after compaction** | The 🧠 context hook |
| **Audit config changes** | Logging and undoing settings changes (see [Config changes](#config-changes)) |
| **Log Claude's actions** | The 📜 audit trail (see [Audit trail](#audit-trail)) |

---

## Hooks

Each script explains itself in its header. This is the map.

### 🛡️ Guards — `scripts/guards/`

| Script | Runs | Does |
|---|---|---|
| `guard-bash.sh` | Before a shell command | Blocks destructive commands (`rm -rf /`, force-push to main…), and asks you before deleting a folder (build output, caches and temp folders excepted) |
| `protect-files.sh` | Before a read, edit, search or shell command | Blocks access to protected files. **The list is at the top of this script.** |
| `protect-plugin.sh` | Before an edit or shell command | Blocks changes to installed plugins |
| `sync-deny-rules.sh` | Session start | Checks your settings also protect those files |
| `audit-config.sh` | When a settings or skill file changes | Logs it, and undoes unsafe changes |

### ✅ Linters — `scripts/linters/`

| Script | Runs | Does |
|---|---|---|
| `check-tools.sh` | Session start | Asks Claude to install any missing linters |
| `lint-java.sh` | After an edit | Java: format, then Checkstyle, then PMD |
| `lint-config.sh` | After an edit | JSON (jq) and YAML (yamllint) |

### 🧠 Context — `scripts/context/`

| Script | Runs | Does |
|---|---|---|
| `session-start.sh` | Session start | Tells Claude the git branch |
| `restore-context.sh` | After compaction | Re-adds your messages and the git state |

### 🔔 Notify — `scripts/notify/`

| Script | Runs | Does |
|---|---|---|
| `notify-desktop.sh` | When Claude waits for you, and when a turn ends | Desktop notification |

### 📜 Audit — `scripts/audit/`

| Script | Runs | Does |
|---|---|---|
| `log-actions.sh` | After Claude runs a command or changes a file | Adds one line to the audit trail |
| `show-actions.sh` | You run it | Shows the audit trail as a table |

---

## Good to know

### Protected files

Protected in two layers, because neither covers everything alone:

| Layer | Covers |
|---|---|
| `protect-files.sh` hook | Deleting files and folders, and shell commands that reach a protected file, by name, wildcard (`.en?`) or symlink |
| Deny rules in `~/.claude/settings.json` | Reading, editing and **searching** |

<details>
<summary>Why two layers?</summary>

A hook can only allow or block a whole search, so a search over the whole
project would either show protected files or be blocked entirely. Claude Code's
deny rules work inside the search and drop just the protected files. Plugins
can't add deny rules, which is why you install them yourself (Quick start,
step 3). `sync-deny-rules.sh` checks them at every session start.

</details>

- **To change the list:** edit `patterns` in `protect-files.sh`, reinstall, then
  run `sync-deny-rules.sh --install` again.
- **Limit:** it reads the command text, so a program that opens files itself
  (e.g. a Python script) or a name built at run time (`$(printf …)`) isn't
  stopped.

### Config changes

`audit-config.sh` watches your settings files while a session is open, whoever
edits them, and logs every change (setting names only, never values) to
`~/.claude/plugins/data/dev-toolkit-local-plugins/config-changes.jsonl`.

**Undone automatically:** `disableAllHooks: true` · removing a protected-file
deny rule · disabling dev-toolkit · `bypassPermissions`.
**Invalid JSON** is ignored until fixed, but left in the file so a half-typed
edit isn't lost.

> **Heads-up:** it can undo a change you meant, such as switching off a broken
> hook. Turn off **Audit config changes** in `/config` first (it may only apply
> from the next session), or edit with Claude Code closed.

### Audit trail

Every command Claude runs and every file it changes, across all projects and
subagents, one JSON line each in
`~/.claude/plugins/data/dev-toolkit-local-plugins/actions.jsonl`.

**Read it** with the viewer:

```
scripts/audit/show-actions.sh                    # latest 30
scripts/audit/show-actions.sh --today --failed   # today's failures and denials
scripts/audit/show-actions.sh --project my-app --last 100
```

```
TIME         RESULT  PROJECT  TOOL   TARGET                     DETAIL
10-02 22:10  ok      my-app   Bash   npm install
10-02 22:11  ok      my-app   Edit   …/src/App.java
10-02 22:12  FAILED  my-app   Bash   npm test                   Exit code 1: 3 failed
```

| Field | What it holds |
|---|---|
| `time`, `session`, `folder`, `tool` | When, which session, which project, which tool |
| `target` | The command (secrets masked), or the file path |
| `result` | `ok`, `failed` (with `error`) or `denied` (with `reason`) |
| `agent` | The subagent, if a subagent did it |

- **Not logged:** reads and searches, file contents, command output, MCP inputs.
- **Secrets** in commands are masked by pattern (tokens, `*KEY=`, `--password`, `-u user:pass`,
  URL passwords). An unusual secret format can still get through.
- **Cost:** no tokens, about 8 ms per action, about 140 bytes per line. The
  latest 20,000 actions are kept (about 3 MB).

### Notifications

- **macOS:** if none appear, allow notifications for **Script Editor** in System
  Settings → Notifications.
- **Linux:** needs `notify-send` (package `libnotify-bin`).
- They come from the OS, so they work inside VS Code too.

---

## Adding to the toolkit

Run `claude plugin validate .` before reinstalling.

### Layout

```
dev-toolkit/
├── .claude-plugin/plugin.json   name, version, settings (userConfig)
├── hooks/hooks.json             which script runs on which event
├── scripts/                     hook scripts, by purpose
│   ├── guards/   linters/   context/   notify/   audit/
├── skills/                      skills (none yet)
├── agents/                      subagents (none yet)
└── .mcp.json                    MCP servers
```

### Add a hook

1. Put the script in the folder for its purpose (or a new folder), named
   `<action>-<target>.sh`, e.g. `linters/lint-python.sh`.
2. Copy the header from any existing script and fill it in: summary, hook,
   requirements, what it does, exit codes.
3. Register it in `hooks/hooks.json`.

**House rules**

| Rule | Why |
|---|---|
| Exit 2 to talk to Claude | stderr is sent to Claude so it can react |
| Don't block on missing tools | Tell Claude how to install them instead |
| Read stdin once | It can't be read twice; save it to a variable |
| Stay portable | Must run on macOS and Linux bash |
| One script per job | Hooks on the same event run in parallel |

### Add a skill, agent, MCP server or setting

| To add | Do this |
|---|---|
| **Skill** | `skills/<name>/SKILL.md` with `name` and `description` frontmatter. The description decides when Claude uses it, so be specific. |
| **Agent** | `agents/<name>.md` with `name`, `description` and `tools` frontmatter. Give it only the tools it needs. |
| **MCP server** | An entry in `.mcp.json`. Refer to plugin files with `${CLAUDE_PLUGIN_ROOT}`. |
| **Setting** | An entry in `userConfig` in `plugin.json`. It appears in `/config`; scripts read it as `CLAUDE_PLUGIN_OPTION_<KEY>`. |
