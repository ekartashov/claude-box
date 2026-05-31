This `DESIGN.md` documents the **technical architecture**, the **solved failures**, and the **security model** for future reference.

---

# DESIGN.md: Claude Code Podman Sandbox

## 1. Problem Statement
Claude Code is an "agentic" tool. To be useful, it requires:
1. **Filesystem Write Access**: To refactor and create files.
2. **Shell Execution**: To run tests, build tools, and linter commands.
3. **Persistent Identity**: To maintain Claude Pro subscription status without re-authenticating every session.
4. **IDE Integration**: To work seamlessly with VSCode/VSCodium extensions, including session history visible in the IDE sidebar.

Running this natively on a Debian workstation poses a security risk (unrestricted shell access) and an environment risk (NPM/Node pollution).

## 2. Architectural Decisions

### A. Rootless Podman vs. Docker
**Decision:** Standardize on rootless Podman.
**Logic:** On Debian, rootless Podman runs within a user namespace. Even if the AI manages to "break out" of the container, it still only has the privileges of the unprivileged host user. Unlike Docker, there is no background daemon running as root that can be exploited.

### B. User Identity Mapping (`--userns=keep-id`)
**Decision:** Force the container to run as the `node` user (UID 1000).
**Logic:**
* **The "Root-Owned Files" Problem:** Standard containers run as root inside. Any file the AI creates in a bind-mount would be owned by `root` on your host, requiring `sudo` to delete or edit them later.
* **The Solution:** By using `--userns=keep-id` and mapping to the internal `node` user (which is also UID 1000), we achieve **perfect UID parity**. Files created by the AI inside the sandbox are owned by you on the host.

### C. Persistent Storage

**v1:** Named Podman volume (`claude-data`) mounted to `/home/node`.
**Problem:** The volume was opaque — not browsable or backable-up without entering a container. Entire `/home/node` was persisted including NPM cache and bash history.

**v2:** Bind-mount `~/.claude-box/` → `/home/node/.claude/`.
**Problem:** `~/.claude-box/` is a custom path unknown to the VSCodium extension. The extension's native binary writes session stubs (title entries) to `~/.claude/`, while the container wrote full session data to `~/.claude-box/projects/`. The extension could display session titles but loading them failed because the full data was in a different directory.

**v3 (current):** Bind-mount `~/.claude/` → `/home/node/.claude/` and `~/.claude.json` → `/home/node/.claude.json`.
**Logic:**
* These are the exact paths the VSCodium extension's native binary reads and writes.
* The container and the extension share a single source of truth for sessions, auth tokens, and project metadata.
* Only the `.claude/` directory and `.claude.json` file are persisted — auth tokens, sessions, projects, and settings.
* The host directory is a regular folder — conversations are visible, greppable, and backable-up with standard tools.
* NPM cache, bash config, and other ephemeral home directory content is discarded with each container run.

### D. Project Path Mapping

**v1/v2 Problem:** The workspace was always mounted to `/workspace`. Claude Code keys project session storage by the working directory path, so every project's sessions were stored under `.claude/projects/-workspace/`, mixing all projects together.

**v3 (current):** Mount `$PWD` at its **real host path** inside the container (`-v "$PWD:$PWD"`, `-w "$PWD"`).
**Logic:**
* Claude Code stores sessions under a path derived from the working directory (e.g. `/srv/my-project` → `projects/-srv-my-project/`).
* The VSCodium extension uses the same real host path when looking up sessions.
* Mounting at the real path makes both agree on the project key, so sessions created in the terminal appear in the IDE sidebar and vice versa.

### E. VSCode/VSCodium Integration

**Decision:** Use the `claudeCode.claudeProcessWrapper` extension setting.
**Logic:**
* The official Claude Code extension has a config key `claudeCode.claudeProcessWrapper` that lets you specify a custom executable to launch Claude.
* When set to `claude-box`, the extension calls: `claude-box /path/to/native-binary [args...]`
* The wrapper detects the native binary path (first argument ending in `/claude`) and discards it, using the containerized `claude` instead.
* The wrapper auto-detects whether it's running interactively (terminal → `-it`) or as a pipe (VSCodium → `-i`), ensuring JSON protocol communication works correctly.

## 3. Solved Issues & Logic Iterations

### Failure: "Login doesn't stick" (v1)
* **Cause:** The `node:slim` image defaults to `/root` as the home directory. When running as a non-root user via `keep-id`, the application was attempting to write config files to `/root` but lacked permissions.
* **Fix:** Explicitly switched the container to `USER node` and set `ENV HOME=/home/node`.

### Failure: "Manual OAuth Link"
* **Cause:** Containers are headless. The standard OAuth loop expects to open a local browser.
* **Fix:** Acceptance of the "Manual Flow." The CLI provides a URL and accepts a pasted code. This is more secure as it doesn't open temporary listener ports on the host.

### Failure: "VSCodium auth status parse failed" (v2)
* **Cause:** The VSCodium extension calls `claude-box <native-binary> auth status` and parses the JSON output. In v1, the wrapper ran the container with `-it` even in pipe mode (non-interactive), corrupting the JSON output with terminal control sequences.
* **Fix:** v2 detects TTY state: `-it` for interactive terminal, `-i` for pipe mode. The non-interactive mode produces clean JSON output that the extension can parse.

### Failure: "ripgrep IO errors in logs" (v2)
* **Cause:** Claude Code expects `rg` (ripgrep) to be installed and various directories (plugins/cache, output-styles) to exist.
* **Fix:** Added `ripgrep` to the Containerfile and pre-created the expected directory stubs.

### Failure: "No conversation found with session ID" (v3)
* **Cause:** Two separate storage paths. The VSCodium extension's native binary wrote session title stubs to `~/.claude/projects/<real-path>/`. The container stored full session data in `~/.claude-box/projects/-workspace/`. The extension found the stub (showing the title in the sidebar) but got "no conversation found" when trying to load it.
* **Fix:** Switch to `~/.claude/` + `~/.claude.json` (shared with the extension) and mount the project at its real host path so the project key matches.

### Failure: "Claude cannot run script/test"
* **Cause:** Agentic AI often assumes standard environment tools are available (Python, etc.). The base `node:slim` image is too minimal for many development tasks.
* **Fix:** Included `python3`, `jq`, and `build-essential` in the default image to handle common development and data processing requirements.

## 4. Security Model

### The "Blast Radius"
The sandbox is restricted by two main boundaries:
1. **Filesystem:** Only the current directory (`$PWD`) is mounted at its real path. The AI cannot see your `Documents`, `Downloads`, `.ssh` keys, or other projects.
2. **Process:** The `--security-opt no-new-privileges` flag prevents privilege escalation.
3. **Credentials:** OAuth tokens live in `~/.claude.json` on the host, owned by your user. They're not accessible from other containers.

### The "Nuke" Scenario
If you ask Claude to `rm -rf /`, it will:
1. Delete the ephemeral container OS (restored on next run).
2. Delete your **current project files** in the bind mount.
3. **It will NOT** touch your host's system files, home directory contents outside `$PWD`, or other projects.

**Recovery Policy:** Always run `claude-box` on a clean Git branch. The sandbox protects the OS; Git protects the code.

## 5. File Layout

```
~/.claude/                        Host persistence directory
├── projects/                     Per-project conversations
│   └── -srv-my-project/          Keyed by real host path
│       ├── <uuid>.jsonl          Individual conversation log
│       └── MEMORY.md             Project memory
├── sessions/                     Active session state
├── plugins/                      Plugin data
├── backups/                      Auto-backups
├── cache/                        Temporary data
├── plans/                        Saved plans
└── telemetry/                    Usage telemetry

~/.claude.json                    OAuth tokens & project index
```

## 6. Maintenance Logic

* **Updating:** `claude-box --update` rebuilds the image with `--no-cache` to fetch the latest Claude Code.
* **Backup:** `cp -a ~/.claude/ ~/backup/claude/ && cp ~/.claude.json ~/backup/`
* **Credential cleanup:** `rm ~/.claude.json`
* **Migration from v2:** `rsync -a ~/.claude-box/ ~/.claude/` then copy `~/.claude-box/.claude.json` to `~/.claude.json`.

---
*Created: April 2026*
*Current Version: v3 (Shared ~/.claude/ + Real CWD Path)*
