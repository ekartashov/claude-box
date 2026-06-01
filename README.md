# Claude Code Podman Sandbox

A high-isolation environment for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) inside rootless Podman on Debian/Linux. The AI operates in a restricted container — it can only see the current project directory and cannot access your host files, SSH keys, or other projects.

**Works with:** Terminal (interactive), VSCode, and VSCodium.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Host (Debian, UID 1000)                                    │
│                                                             │
│  ~/.local/bin/claude-box     ← wrapper script               │
│  ~/.claude/                  ← conversations, auth, config  │
│      ├── .claude.json        ← OAuth credentials            │
│      ├── projects/           ← per-project conversation logs│
│      │   └── -srv-my-proj/   ← keyed by real host path      │
│      └── ...                                                │
│                                                             │
│  VSCodium extension ──────┐                                 │
│    claudeProcessWrapper ──┼──→ claude-box ──→ podman run    │
│                           │                                 │
│  Terminal ────────────────┘                                 │
└─────────────────────────────────────────────────────────────┘
          │                           │
          ▼                           ▼
┌──────────────────┐    ┌──────────────────────────────────┐
│  claude-sandbox  │    │  Bind Mounts                     │
│  (container)     │    │                                  │
│  node:22-slim    │    │  ~/.claude/     → .claude/        │
│  + claude-code   │    │  ~/.claude.json → .claude.json    │
│  + git, rg, curl │    │  $PWD           → $PWD (same path)│
│  + python, jq    │    │                                  │
└──────────────────┘    └──────────────────────────────────┘
```

## Pre-installed Tools

The sandbox comes pre-equipped with essential tools that Claude Code frequently uses for planning and execution:

*   **Search**: `ripgrep` (rg) for fast codebase indexing.
*   **Scripting**: `python3` (with `pip` and `venv`) for data processing and automated scripts.
*   **JSON Processing**: `jq` for manipulating API responses and configuration files.
*   **Build Essentials**: `make`, `gcc`, and other compilers to handle project dependencies.
*   **Network**: `curl` and `ca-certificates` for webhooks and MCP servers.

The project directory is mounted at its **real host path** (e.g. `/srv/my-project` →
`/srv/my-project`), not at a fixed `/workspace`. This ensures Claude Code keys session
storage consistently whether accessed from the terminal or the VSCodium extension.

## Quick Start

### 1. Clone & Install

```bash
git clone <repo-url> && cd claude-box
bash install.sh
```

This will:
- Copy `claude-box` to `~/.local/bin/`
- Create `~/.claude/` for persistent data
- Build the container image
- Optionally migrate data from an older layout

### 2. Authenticate

```bash
cd ~/any-project
claude-box
```

On first run, copy the URL into your browser, sign in with your Claude account, and paste the code back.

### 3. Use

| Task | Command |
| :--- | :--- |
| Interactive session | `claude-box` |
| Continue last session | `claude-box -c` |
| Resume picker | `claude-box -r` |
| One-shot prompt | `claude-box -p "fix the tests"` |
| High-reasoning mode | `claude-box --effort max` |
| Open debug shell | `claude-box --shell` |

---

## VSCode / VSCodium Integration

Claude Code's extension supports a custom process wrapper. Set it in your editor's `settings.json`:

```json
{
    "claudeCode.claudeProcessWrapper": "/home/<your-user>/.local/bin/claude-box"
}
```

The extension will invoke `claude-box` instead of the native `claude` binary, routing all communication through the sandboxed container.

Because the container mounts `~/.claude/` and `~/.claude.json` from the host, the extension and the container share the same session history, auth tokens, and project index. Sessions started in the terminal are visible in the IDE and vice versa.

> **Note:** The extension bundles its own Claude binary. The wrapper detects this and transparently substitutes the containerized version. Minor version differences between the extension's binary and the container's CLI are generally harmless.

---

## Conversation Persistence

All Claude Code state lives in standard locations on your host:

```
~/.claude/
├── projects/                 # Per-project conversation logs (.jsonl)
│   └── -srv-my-project/      # Keyed by real host path
│       ├── <uuid>.jsonl      # Individual conversation
│       └── MEMORY.md         # Project memory
├── sessions/                 # Active session state
├── plugins/                  # Plugin data
├── backups/                  # Auto-backups of configuration
├── cache/                    # Temporary cache data
├── plans/                    # Saved plans
└── settings.json             # Claude Code user settings

~/.claude.json                # OAuth tokens & project index
```

**Backup:** `cp -a ~/.claude/ ~/backup/claude/ && cp ~/.claude.json ~/backup/`

**Reset auth:** `rm ~/.claude.json`

---

## Project Configuration Templates

When integrating `claude-box` into a new project repository, we highly recommend copying the provided `.template` files into your project root. These prompts condition Claude to understand its environment boundaries.

*   **`CLAUDE.local.md.template`**: Copy to your project root as `CLAUDE.local.md`. This template instructs Claude about the underlying `claude-box` sandboxed architecture (e.g., exact path mounting, shared `~/.claude` state). It acts as a universal reference.
*   **`CLAUDE.md.template`**: Copy to your project root as `CLAUDE.md`. This holds your project-specific business logic boundaries. The provided template serves as a strong starting point—teaching Claude that although it can use container-local `Python`, it cannot access the host GPU or trigger other orchestration scripts from within the sandbox. Adapt these specific project rules to match your codebase.

---

## Maintenance

### Update Claude Code
```bash
claude-box --update
```

### Rebuild Image
```bash
claude-box --build
```

### Migrate from Old Volume
If you previously used the `claude-data` Podman volume:
```bash
claude-box --migrate
```

### View Claude Version
```bash
claude-box --version
```

---

## Security Model

| Layer | Protection |
| :--- | :--- |
| **Filesystem** | Only `$PWD` is mounted. No access to `~/.ssh`, `~/Documents`, etc. |
| **Process** | `--security-opt no-new-privileges` blocks privilege escalation |
| **User** | `--userns=keep-id` maps container → host UID. No root-owned files. |
| **Network** | Full network access (required for API calls). Restrict with `--network=none` if using API key mode. |

**Recovery policy:** Always run on a Git branch. The sandbox protects your OS; Git protects your code. If Claude does something destructive in the project directory, `git reset --hard` from the host recovers everything.

---

## Environment Variables

| Variable | Default | Description |
| :--- | :--- | :--- |
| `CLAUDE_BOX_IMAGE` | `claude-sandbox:latest` | Container image to use |
| `CLAUDE_DIR` | `~/.claude` | Host directory for persistent data |
| `CLAUDE_JSON` | `~/.claude.json` | Host config/auth file |
| `CLAUDE_BOX_MOUNTS`| _(empty)_ | Space-separated list of extra volumes to mount (e.g., `/foo:/foo:rw,z /bar:/bar:ro,z`) |
| `CLAUDE_BOX_DEBUG` | `0` | Set to `1` to generate a randomized user-specific debug log file in `/tmp/` |
