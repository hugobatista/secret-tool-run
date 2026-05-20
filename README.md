[![GitHub Tag](https://img.shields.io/github/v/tag/hugobatista/secret-tool-run?logo=github&label=latest)](https://go.hugobatista.com/gh/secret-tool-run/releases)

# secret-tool-run 🔐

**Execute commands with secrets from keyring, not from disk.**

secret-tool-run is a bash utility that runs commands with environment secrets loaded from your system's secure keyring (through secret-tool), eliminating the need to store `.env` files on disk. Perfect for developers who want to keep credentials off the filesystem while maintaining a smooth development workflow.


## Quick Example

Instead of this (storing secrets on disk):
```bash
# ❌ Dangerous: secrets exposed on filesystem
cat .env  # DATABASE_PASSWORD=super_secret
python app.py
```

Do this (secrets from keyring):
```bash
# ✅ Secure: secrets loaded from keyring, never persisted to disk
secret-tool-run python app.py
```

**Under the hood:** secret-tool-run retrieves your secrets from the system keyring (encrypted and managed by the OS) through secret-tool and passes them to your command — no permanent `.env` files on disk. It has three modes: **file mode** (default) writes a temp `.env` with secure permissions and deletes it after; **file descriptor mode** (`@SECRETS@`) passes secrets via an in-memory FD with zero disk writes; **source mode** (`--source`) exports secrets as real environment variables without writing any file.


## Prerequisites

- **Linux** with a keyring service (GNOME Keyring, KWallet, etc.)
- **bash** (4.0+)
- **secret-tool** from `libsecret-tools` package


## Installation

### One-liner (Recommended)

Installs secret-tool-run to `~/.local/bin`:
```bash
curl -fsSL https://go.hugobatista.com/ghraw/secret-tool-run/main/install.sh | sh
```

### Or clone and install locally

Download the repository and run the installer:

```bash
git clone https:/go.hugobatista.com/gh/secret-tool-run.git
cd secret-tool-run
./install.sh
```

The installer will:
1. Check for dependencies
2. Let you choose between system-wide (`/usr/local/bin`) or user-local (`~/.local/bin`) installation
3. Set up the `secret-tool-run` command
4. Verify the installation

## Usage

```bash
secret-tool-run [OPTIONS] COMMAND [ARGS...]
```

### Options

| Option | Description |
|--------|-------------|
| `--file FILE`, `-f FILE` | Secrets file path (default: `.env`) |
| `--app APP`, `-a APP` | Keyring app identifier (default: current folder name) |
| `--source`, `-s` | Source and export `.env` vars into the environment |
| `--help`, `-h` | Show help message |


## Modes of Operation

secret-tool-run has three modes for passing secrets to your command:

| Mode | How to enable | How secrets arrive | Writes to disk? |
|------|--------------|-------------------|-----------------|
| **File** (default) | No flag | Temp `.env` file, `SECRETS_FILE` points to it | Temp file, auto-deleted |
| **File Descriptor** | `@SECRETS@` token in args | In-memory FD as `/dev/fd/9`, `SECRETS_FILE=/dev/fd/9` | Never |
| **Source** | `--source` / `-s` flag | Exported as real environment variables via `set -a` | Never |

Pick the mode that matches how your tool reads secrets. The examples below show each mode in action.

## Examples

### Example 1: Python development with uv

```bash
secret-tool-run uv run pywrangler dev
```

**What happens:**
1. Loads `.env` from keyring for current folder
2. Creates temporary `.env` file
3. Runs `uv run pywrangler dev` with secrets available
4. Deletes `.env` after command completes

### Example 2: Python project with hatch

```bash
secret-tool-run hatch run dev
```

Perfect for running development servers where you need environment variables but don't want them persisted on disk.

### Example 3: Ansible playbook with environment variables

```bash
secret-tool-run --source ansible-playbook site.yml
```

**Before secret-tool-run:**
```bash
source .env && ansible-playbook site.yml
```

**What happens with `--source`:**
1. Loads secrets from keyring (or uses local `.env` file if it exists)
2. Sources every `KEY=VALUE` pair into the environment (via `set -a`)
3. Runs `ansible-playbook site.yml` with all env vars available
4. No temp file is needed when loading from keyring — secrets stay in memory

Useful for any tool that expects secrets as environment variables — Ansible, Terraform, custom scripts, etc.

### Example 4: GitHub Actions local testing with act

```bash
secret-tool-run --file .secrets act --secret-file .secrets
```

**What happens:**
1. Uses custom file name `.secrets` instead of `.env`
2. Loads or prompts for secrets under that filename
3. Runs `act` with the secrets file
4. Cleans up `.secrets` after execution

This is especially useful for testing GitHub Actions workflows locally while keeping production secrets secure.

### Example 5: Multiple environments with custom app names

```bash
# Development environment
secret-tool-run --app myproject-dev npm start

# Production environment
secret-tool-run --app myproject-prod npm start
```

Each `--app` name is a separate keyring entry, allowing you to manage different secret sets (dev, staging, prod) for the same project.

### Example 6: Docker commands

```bash
secret-tool-run docker-compose up
```

Great for docker-compose files that source `.env` for configuration.

### Example 7: Just viewing the secrets file path

```bash
secret-tool-run env | grep SECRETS_FILE
```

The `SECRETS_FILE` environment variable contains the absolute path to the secrets file created by secret-tool-run.

### Example 8: File descriptor mode (no disk I/O)

```bash
secret-tool-run act --secret-file @SECRETS@
```

**What happens:**
1. Detects `@SECRETS@` token in arguments
2. Loads secrets from keyring into memory
3. Creates file descriptor at `/dev/fd/9` (no disk write)
4. Replaces `@SECRETS@` with `/dev/fd/9`
5. Runs `act` which reads secrets from the file descriptor
6. FD automatically closes - no cleanup needed

**Perfect for:**
- GitHub Actions local testing with `act`
- Docker with `--env-file`
- Any tool that can read from file descriptors

**Won't work for:**
- Shell sourcing (`source $SECRETS_FILE`)
- Tools that verify file exists with stat checks
- Tools that need to read the file multiple times

### Example 9: Docker with file descriptor mode

```bash
secret-tool-run docker run --env-file @SECRETS@ myimage
```

Secrets are loaded from keyring and passed to Docker without ever touching the disk. The `@SECRETS@` token automatically enables zero-disk-I/O mode.

## Advanced Features

### Preventing Auto-Cleanup (File Mode Only)

In **file mode** (the default), secret-tool-run deletes the temporary `.env` file after your command finishes. Create a `.keep` file to prevent this:

```bash
touch .env.keep
secret-tool-run your-command
# .env will remain after execution
```

This is useful for:
- Debugging secrets content
- Running multiple commands without reloading
- IDE integration where the editor expects a persistent file

### Custom Secrets File Locations

```bash
# Use a different file name
secret-tool-run --file .env.production npm run build

# Use a path in a different directory
secret-tool-run --file /tmp/my-secrets ./deploy.sh
```

### SECRETS_FILE Environment Variable

In **file mode** and **FD mode**, your command receives `SECRETS_FILE` pointing to the secrets source:

```bash
# File mode: points to temp .env
secret-tool-run bash -c 'echo "Secrets are at: $SECRETS_FILE"'
# FD mode: points to /dev/fd/9
secret-tool-run bash -c 'echo "Secrets are at: $SECRETS_FILE"' --secret-file @SECRETS@
```

In **source mode** (`--source`), `SECRETS_FILE` is not set — the secrets are already in the environment.

### File Descriptor Mode (No Disk I/O)

For maximum security, use the `@SECRETS@` token in your command to pass secrets via file descriptor without writing to disk:

```bash
secret-tool-run act --secret-file @SECRETS@
```

**How it works:**
- secret-tool-run detects the `@SECRETS@` token in your command arguments
- Loads secrets from keyring into memory only
- Creates file descriptor at `/dev/fd/9` (no disk write)
- Replaces `@SECRETS@` token with `/dev/fd/9` in all arguments
- Your command reads from the FD as if it were a file
- No temp file created, no cleanup needed
- FD automatically closes when command completes

**Security benefits:**
- Zero disk I/O - secrets never touch the filesystem
- No directory entry visible in `ls`
- Automatic cleanup (pipe closes on exit)
- No permission race conditions
- No accidental `.keep` file keeping secrets around
- Simple, explicit syntax - just use `@SECRETS@` where you need it

**Compatibility:**

✅ **Works with these tools:**
```bash
secret-tool-run act --secret-file @SECRETS@
secret-tool-run docker run --env-file @SECRETS@ image
```

Replaced tokens work just like file paths:
```bash
secret-tool-run mycommand --config @SECRETS@ --output results.txt
# All @SECRETS@ tokens are replaced with /dev/fd/9
```

### Source Mode (Environment Variable Export)

For tools that expect secrets as actual environment variables (like Ansible, shell scripts, or tools that call `os.getenv`), use the `--source` flag:

```bash
secret-tool-run --source ansible-playbook site.yml
```

**How it works:**
- Before running your command, secret-tool-run sources the secrets using `set -a` (allexport)
- This exports every `KEY=VALUE` pair as a real environment variable
- Your command sees them exactly as if you had run `source .env` manually
- **No temp file is written** — secrets are loaded directly from keyring into memory
- Works with `@SECRETS@` too — sources from keyring directly into env without touching disk
- When a local `.env` file already exists (not loaded from keyring), it is sourced directly from disk

**Which tools benefit from `--source`?**

| Tool | Without --source | With --source |
|------|-----------------|---------------|
| Ansible | `source .env && ansible-playbook ...` | `secret-tool-run --source ansible-playbook ...` |
| Terraform | `source .env && terraform plan` | `secret-tool-run --source terraform plan` |
| Shell scripts | `source .env && ./deploy.sh` | `secret-tool-run --source ./deploy.sh` |
| Any `os.getenv`/`$VAR` consumer | needs vars in environment | vars are exported automatically |

**Key difference:** without `--source`, secrets are written to a temp file and `SECRETS_FILE` env var is set.
With `--source`, secrets are loaded directly into memory — no temp file, no `SECRETS_FILE`, just real env vars.

**Combined with `@SECRETS@`:**
```bash
secret-tool-run --source ansible-playbook --vault-password-file @SECRETS@ site.yml
```
This both sources secrets into the environment AND passes one via file descriptor — maximum flexibility with zero disk writes.

### First-Run Setup

On first use (when secrets aren't in keyring):

1. secret-tool-run prompts: "Paste your secrets content..."
2. Paste your `.env` content (KEY=VALUE format)
3. Press `Ctrl-D` to finish (or `Ctrl-C` to cancel)
4. Secrets are encrypted and stored in system keyring
5. Future runs load automatically

## Security Notes

- **Keyring encryption**: Secrets stored in your system's encrypted keyring service
- **File permissions** (file mode): Temporary files created with `600` permissions (owner read/write only)
- **Short-lived exposure** (file mode): Files on disk exist only during command execution
- **Zero disk I/O**: Use `@SECRETS@` (FD mode) or `--source` (source mode) — secrets never touch disk
- **No git commits**: No `.env` files left behind to commit accidentally
- **Session isolation**: Each terminal session can use different secrets with `--app` flag

**⚠️ Important**: While secret-tool-run improves security, temporary files are still written to disk briefly in file mode. For maximum security:
- **Use `@SECRETS@`** for tools that accept a file path (FD mode — zero disk I/O)
- **Use `--source`** for tools that need env vars (source mode — zero disk I/O)
- Use encrypted home directories
- Ensure your keyring is properly locked when not in use
- Be cautious running secret-tool-run on shared systems

## Troubleshooting

### "Command fails with @SECRETS@"

The command may require a regular file instead of a file descriptor. Try without the `@SECRETS@` token:

```bash
# If this fails:
secret-tool-run mycommand --file @SECRETS@

# Try this instead:
secret-tool-run mycommand
```

### "No secrets found" on every run

Check if secrets are actually stored:

```bash
secret-tool search app "$(basename $PWD)"
```

If nothing appears, the keyring store failed. Try storing manually:

```bash
secret-tool store --label "Test" app "my-test"
# Paste your secret, press Ctrl-D
secret-tool lookup app "my-test"
```

### Secrets file not deleted after run

Check for a `.keep` file:

```bash
ls -la .env.keep
```

Remove it to restore auto-cleanup:

```bash
rm .env.keep
```

### Want to delete stored secrets

```bash
# List secrets for current folder
secret-tool search app "$(basename $PWD)"

# Delete specific entry
secret-tool clear app "$(basename $PWD)"

# Or for a specific app name
secret-tool clear app "myproject-prod"
```

### Command fails but secrets file remains

If your command crashes before secret-tool-run's cleanup trap runs, manually remove:

```bash
rm .env  # or your custom secrets file name
```

## Uninstallation

Run the uninstall script:

```bash
./uninstall.sh
```

This will:
1. Remove the `secret-tool-run` binary
2. Optionally help you clear keyring entries

To manually clear all secret-tool-run secrets from keyring:

```bash
# List all entries
secret-tool search app ""

# Remove specific ones
secret-tool clear app "your-app-name"
```
