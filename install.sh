#!/usr/bin/env bash
# install.sh — Install claude-box to ~/.local/bin
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin"

# claude-box uses ~/.claude/ and ~/.claude.json — the same paths the
# VSCodium extension's native binary uses, so sessions are shared.
CLAUDE_DIR="${HOME}/.claude"
CLAUDE_JSON="${HOME}/.claude.json"

info() { printf '\033[1;34m→\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }

# ─── Pre-flight checks ───────────────────────────────────────────────────────
if ! command -v podman &>/dev/null; then
    printf '\033[1;31merror:\033[0m podman is not installed\n' >&2
    exit 1
fi

# ─── Install the script ──────────────────────────────────────────────────────
info "Installing claude-box to $INSTALL_DIR/"
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/claude-box" "$INSTALL_DIR/claude-box"
chmod +x "$INSTALL_DIR/claude-box"
ok "claude-box installed to $INSTALL_DIR/claude-box"

# ─── Create persistence directories ──────────────────────────────────────────
info "Creating persistence directory at $CLAUDE_DIR/"
mkdir -p "$CLAUDE_DIR"/{plugins/cache,output-styles,sessions,projects,cache,backups,session-env,shell-snapshots,telemetry,plans}
[[ -f "$CLAUDE_JSON" ]] || echo '{}' > "$CLAUDE_JSON"
ok "Persistence directory ready at $CLAUDE_DIR/"

# ─── Migrate from old ~/.claude-box/ layout (if it exists) ───────────────────
OLD_HOME="${HOME}/.claude-box"
if [[ -d "$OLD_HOME" ]]; then
    warn "Found old persistence directory at $OLD_HOME/"
    printf '   Migrate data to %s? [y/N] ' "$CLAUDE_DIR"
    read -r answer
    if [[ "$answer" =~ ^[Yy] ]]; then
        rsync -a --ignore-existing "$OLD_HOME/" "$CLAUDE_DIR/"
        # The old layout stored .claude.json inside the dir; move it out
        if [[ -f "$OLD_HOME/.claude.json" && ! -s "$CLAUDE_JSON" ]]; then
            cp "$OLD_HOME/.claude.json" "$CLAUDE_JSON"
        fi
        ok "Migration complete — old data copied to $CLAUDE_DIR/"
        info "Original $OLD_HOME/ left intact. Remove it manually once verified."
    else
        info "Skipped migration. Run 'rsync -a ~/.claude-box/ ~/.claude/' manually if needed."
    fi
fi

# ─── Migrate from old named volume (if exists) ───────────────────────────────
if podman volume exists claude-data 2>/dev/null; then
    warn "Found old 'claude-data' Podman volume with session data"
    printf '   Migrate data to %s? [y/N] ' "$CLAUDE_DIR"
    read -r answer
    if [[ "$answer" =~ ^[Yy] ]]; then
        "$INSTALL_DIR/claude-box" --migrate
        ok "Migration complete"
    else
        info "Skipped. Run 'claude-box --migrate' later if needed."
    fi
fi

# ─── Build the container image ────────────────────────────────────────────────
info "Building container image..."
podman build -t claude-sandbox:latest -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"
ok "Container image built"

# ─── Check PATH ──────────────────────────────────────────────────────────────
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    warn "$INSTALL_DIR is not in your PATH"
    echo "   Add this to your ~/.bashrc:"
    echo "     export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# ─── Print summary ───────────────────────────────────────────────────────────
echo ""
ok "claude-box installed successfully!"
echo ""
echo "  Quick start:"
echo "    cd /path/to/your/project"
echo "    claude-box                  # Interactive session"
echo "    claude-box --help           # All options"
echo ""
echo "  VSCodium integration:"
echo "    Add to your VSCodium settings.json:"
echo "      \"claudeCode.claudeProcessWrapper\": \"$INSTALL_DIR/claude-box\""
echo ""
echo "  Conversations are stored in:"
echo "    $CLAUDE_DIR/"
echo "    $CLAUDE_JSON"
echo ""
