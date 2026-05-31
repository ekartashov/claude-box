FROM node:22-slim

# System dependencies:
#   git               — Claude Code uses git for context
#   ripgrep           — Claude Code uses rg for fast file search
#   curl              — MCP servers, webhooks, general utility
#   python3           — Scripting and data processing
#   jq                — JSON processing
#   build-essential   — Compiling dependencies/running make
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git ripgrep curl ca-certificates \
       python3 python3-pip python3-venv jq build-essential \
    && rm -rf /var/lib/apt/lists/*

# Python project dependencies for Claude Code in-container use:
#   pydantic          — config/result schemas (lib/scorer.py)
#   httpx             — async HTTP client (lib/client.py)
#   pyyaml            — config/models.yaml, thresholds.yaml parsing
#   rich              — CLI tables and summary output (lib/reporter.py)
#   openai            — OpenAI-compatible vLLM client (lib/client.py)
#   ruff              — lint files before handing back to operator
#   pytest            — run lib unit tests in-container
RUN pip3 install --no-cache-dir --break-system-packages \
    pydantic httpx pyyaml rich openai \
    ruff pytest

# Install Claude Code CLI globally
RUN npm install -g @anthropic-ai/claude-code@latest

# Pre-create directory stubs that Claude Code expects,
# so it doesn't emit noisy "IO error" log lines on startup.
RUN mkdir -p /home/node/.claude/plugins/cache \
             /home/node/.claude/output-styles \
             /home/node/.claude/sessions \
             /home/node/.claude/projects \
             /home/node/.claude/cache \
             /home/node/.claude/backups \
    && chmod -R 777 /home/node/.claude \
    && chmod 777 /home/node

# Set the Home environment variable explicitly
ENV HOME=/home/node

WORKDIR /workspace

ENTRYPOINT ["claude"]
