# vaultsh 🔐

**Execute commands with secrets from keyring, not from disk.**

vaultsh is a bash utility that runs commands with environment secrets loaded from your system's secure keyring, eliminating the need to store `.env` files on disk. Perfect for developers who want to keep credentials off the filesystem while maintaining a smooth development workflow.

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
vaultsh python app.py
```

**Under the hood:** vaultsh retrieves your secrets from the system keyring (encrypted and managed by the OS), creates a temporary file with secure permissions only your process can read, passes it to your command, and deletes it immediately after—leaving no trace on disk.


## Prerequisites

- **Linux** with a keyring service (GNOME Keyring, KWallet, etc.)
- **bash** (4.0+)
- **secret-tool** from `libsecret-tools` package


## Installation

Run the installation script:

```bash
./install.sh
```

The installer will:
1. Check for dependencies
2. Let you choose between system-wide (`/usr/local/bin`) or user-local (`~/.local/bin`) installation
3. Set up the `vaultsh` command
4. Verify the installation

## Usage

```bash
vaultsh [OPTIONS] COMMAND [ARGS...]
```

### Options

| Option | Description |
|--------|-------------|
| `--file FILE`, `-f FILE` | Secrets file path (default: `.env`) |
| `--app APP`, `-a APP` | Keyring app identifier (default: current folder name) |
| `--help`, `-h` | Show help message |


## Examples

### Example 1: Python development with uv

```bash
vaultsh uv run pywrangler dev
```

**What happens:**
1. Loads `.env` from keyring for current folder
2. Creates temporary `.env` file
3. Runs `uv run pywrangler dev` with secrets available
4. Deletes `.env` after command completes

### Example 2: Python project with hatch

```bash
vaultsh hatch run dev
```

Perfect for running development servers where you need environment variables but don't want them persisted on disk.

### Example 3: GitHub Actions local testing with act

```bash
vaultsh --file .secrets act --secret-file .secrets
```

**What happens:**
1. Uses custom file name `.secrets` instead of `.env`
2. Loads or prompts for secrets under that filename
3. Runs `act` with the secrets file
4. Cleans up `.secrets` after execution

This is especially useful for testing GitHub Actions workflows locally while keeping production secrets secure.

### Example 4: Multiple environments with custom app names

```bash
# Development environment
vaultsh --app myproject-dev npm start

# Production environment
vaultsh --app myproject-prod npm start
```

Each `--app` name is a separate keyring entry, allowing you to manage different secret sets (dev, staging, prod) for the same project.

### Example 5: Docker commands

```bash
vaultsh docker-compose up
```

Great for docker-compose files that source `.env` for configuration.

### Example 6: Just viewing the secrets file path

```bash
vaultsh env | grep SECRETS_FILE
```

The `SECRETS_FILE` environment variable contains the absolute path to the secrets file created by vaultsh.

## Advanced Features

### Preventing Auto-Cleanup

Create a `.keep` file to prevent automatic deletion of the secrets file:

```bash
touch .env.keep
vaultsh your-command
# .env will remain after execution
```

This is useful for:
- Debugging secrets content
- Running multiple commands without reloading
- IDE integration where the editor expects a persistent file

### Custom Secrets File Locations

```bash
# Use a different file name
vaultsh --file .env.production npm run build

# Use a path in a different directory
vaultsh --file /tmp/my-secrets ./deploy.sh
```

### SECRETS_FILE Environment Variable

Your command receives the `SECRETS_FILE` environment variable pointing to the secrets file:

```bash
vaultsh bash -c 'echo "Secrets are at: $SECRETS_FILE"'
```

You can use this in scripts that need to know the file location explicitly.

### First-Run Setup

On first use (when secrets aren't in keyring):

1. vaultsh prompts: "Paste your secrets content..."
2. Paste your `.env` content (KEY=VALUE format)
3. Press `Ctrl-D` to finish (or `Ctrl-C` to cancel)
4. Secrets are encrypted and stored in system keyring
5. Future runs load automatically

## Security Notes

- **Keyring encryption**: Secrets stored in your system's encrypted keyring service
- **File permissions**: Temporary files created with `600` permissions (owner read/write only)
- **Short-lived exposure**: Files on disk exist only during command execution
- **No git commits**: Temporary files are created/deleted, reducing risk of accidental commits
- **Session isolation**: Each terminal session can use different secrets with `--app` flag

**⚠️ Important**: While vaultsh improves security, temporary files are still written to disk briefly. For maximum security:
- Use encrypted home directories
- Ensure your keyring is properly locked when not in use
- Be cautious running vaultsh on shared systems



## Uninstallation

Run the uninstall script:

```bash
./uninstall.sh
```

This will:
1. Remove the `vaultsh` binary
```
