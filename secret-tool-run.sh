#!/bin/bash
set -euo pipefail

# secret-tool-run - Execute commands with secrets from keyring, avoiding .env files on disk
# Automatically loads secrets from keyring, creates temporary .env, and cleans up

version="0.3.0"

# Default configuration
secrets_file=".env"
app_name=$(basename "$PWD")
use_fd=false  # Will be set to true if @SECRETS@ token is detected
delete_local_file_after=false  # Will be set to true if user opts to store local file in keyring
source_mode=false              # When true, source and export .env vars before running command
password=""                    # Encryption password (set via --password=PASSWORD)
plaintext_mode=false           # When true, disable encryption (store/read plaintext)

# Setup colored output for terminal
color_on=""
color_off=""
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
	color_on="$(tput setaf 6)"
	color_off="$(tput sgr0)"
fi

# Parse command-line options
while [[ $# -gt 0 ]]; do
  case $1 in
    --file|-f)
      secrets_file="$2"; shift 2 ;;
    --app|-a)
      app_name="$2"; shift 2 ;;
    --source|-s)
      source_mode=true; shift ;;
    --password=*)
      password="${1#*=}"
      shift ;;
    --password)
      shift ;;
    --plaintext)
      plaintext_mode=true
      shift ;;
    --help|-h)
      cat << EOF
Usage: secret-tool-run [OPTIONS] COMMAND [ARGS...]

secret-tool-run $version - Execute commands with secrets loaded from your system keyring,
avoiding the need to store .env files on disk.

Options:
  --file FILE, -f FILE    Secrets file path (default: .env)
  --app APP, -a APP       Keyring app identifier (default: current folder name)
  --source, -s            Source and export .env vars into the environment
  --password[=PASSWORD]   Encrypt secrets with a password (AES-256-CBC via openssl).
                          If PASSWORD is omitted, resolves from SECRET_TOOL_PASSWORD
                          env var or prompts interactively. Encrypted entries are
                          stored under a separate keyring key (app_name-encrypted).
  --plaintext             Disable encryption, store/retrieve secrets as plaintext
                          (default: encryption is enabled).
  --help, -h              Show this help message

Environment:
  SECRET_TOOL_PASSWORD     Encryption password used automatically when set, unless
                          overridden by --password=PASSWORD.

Note: Encryption is enabled by default. All secrets are encrypted before storage.
      Use --plaintext to disable encryption.

How it works:
  1. If secrets file exists locally → use it directly
  2. Otherwise, load from keyring (app name) → create temporary file
  3. If command contains @SECRETS@ token → use file descriptor mode (no disk I/O)
  4. Execute your command with SECRETS_FILE environment variable set
  5. With --source: source and export .env KEY=VALUE pairs before running (default: off)
     In source mode, no temp file is written — secrets are loaded directly into memory
  6. Automatically delete temporary file after execution (not needed with @SECRETS@ or --source)

Examples:
  secret-tool-run uv run pywrangler dev
    Creates .env from keyring, runs command, removes .env

  secret-tool-run hatch run dev
    Loads secrets and runs hatch development server

  secret-tool-run --source ansible-playbook site.yml
    Sources .env into environment so ansible-playbook sees the vars (no manual source needed)

  secret-tool-run --file .secrets act --secret-file .secrets
    Uses custom secrets file for GitHub Actions local testing

  secret-tool-run --app myproject-prod npm start
    Uses specific keyring entry for production secrets

  secret-tool-run act --secret-file @SECRETS@
    ✅ Use @SECRETS@ token for file descriptor mode (zero disk I/O)
    Token auto-enables FD mode, replaced with /dev/fd/9

  secret-tool-run docker run --env-file @SECRETS@ myimage
    ✅ Works with any command, no shell wrapper needed

Advanced:
  - --source, -s: Source and export all variables into the environment before running
    your command. No temp file is written — secrets stay in memory.
    Useful for tools like ansible-playbook that expect env vars.
  - @SECRETS@ token: Use this in any argument to enable file descriptor mode
    Command: secret-tool-run act --secret-file @SECRETS@
    Token is replaced with /dev/fd/9, secrets passed via file descriptor (no disk)
  - Create <secrets-file>.keep (e.g., .env.keep) to prevent auto-deletion
  - SECRETS_FILE env var is set to the file path (or /dev/fd/9 with @SECRETS@)
  - First run prompts for secrets and stores them in keyring automatically
  - Combine --source with @SECRETS@: sources vars into env AND passes FD to command

EOF
      exit 0 ;;
    *)
      break ;;
  esac
done

# Print colored info messages to stdout
info() {
	printf '%s%s%s\n' "$color_on" "$*" "$color_off"
}

# Source .env file and export all KEY=VALUE pairs into the environment
# Uses set -a (allexport) to auto-export every sourced variable
source_and_export() {
  local file="$1"
  if [[ -f "$file" ]]; then
    set -a
    source "$file"
    set +a
  fi
}

# Resolve encryption password for storing new secrets
# Priority: --password=VALUE > SECRET_TOOL_PASSWORD > interactive prompt (with confirm)
# Returns 0 if password was set, 1 if no password available
resolve_encrypt_password() {
  # Already have explicit password from --password=VALUE
  if [[ -n "$password" ]]; then
    return 0
  fi

  # Check SECRET_TOOL_PASSWORD env var
  if [[ -n "${SECRET_TOOL_PASSWORD-}" ]]; then
    password="$SECRET_TOOL_PASSWORD"
    return 0
  fi

  # Interactive prompt with confirmation (if running in terminal)
  if [[ -t 0 ]]; then
    echo >&2  # ensure prompt appears on its own line
    read -s -p "Enter encryption password: " password
    echo >&2
    if [[ -z "$password" ]]; then
      echo "Error: Password cannot be empty." >&2
      return 1
    fi
    read -s -p "Confirm password: " password_confirm
    echo >&2
    if [[ "$password" != "$password_confirm" ]]; then
      echo "Error: Passwords do not match." >&2
      return 1
    fi
    return 0
  fi

  return 1
}

# Resolve decryption password for loading existing encrypted secrets
# Priority: --password=VALUE > SECRET_TOOL_PASSWORD > interactive prompt (no confirm)
# Returns 0 if password was set, 1 if no password available
resolve_decrypt_password() {
  # Already have explicit password from --password=VALUE
  if [[ -n "$password" ]]; then
    return 0
  fi

  # Check SECRET_TOOL_PASSWORD env var
  if [[ -n "${SECRET_TOOL_PASSWORD-}" ]]; then
    password="$SECRET_TOOL_PASSWORD"
    return 0
  fi

  # Interactive prompt (if running in terminal)
  if [[ -t 0 ]]; then
    echo >&2  # ensure prompt appears on its own line
    read -s -p "Enter decryption password: " password
    echo >&2
    if [[ -z "$password" ]]; then
      echo "Error: Password cannot be empty." >&2
      return 1
    fi
    return 0
  fi

  return 1
}

# Check that openssl is available (only called when encryption/decryption is needed)
check_openssl() {
  if ! command -v openssl >/dev/null 2>&1; then
    echo "Error: openssl not found. Please install openssl:" >&2
    echo "  Fedora/RHEL: sudo dnf install openssl" >&2
    echo "  Ubuntu/Debian: sudo apt install openssl" >&2
    echo "  Arch: sudo pacman -S openssl" >&2
    exit 127
  fi
}

# Encrypt plaintext secrets with the resolved password
# Returns base64-encoded ciphertext on stdout
encrypt_secrets() {
  local plaintext="$1"
  printf '%s' "$plaintext" | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -base64 -pass pass:"$password"
}

# Decrypt ciphertext secrets with the resolved password
# Returns plaintext on stdout, exits 1 on failure
decrypt_secrets() {
  local ciphertext="$1"
  # Use a temp file to avoid null byte warnings from partial openssl output
  # Use echo (with trailing newline) because openssl base64 decoder requires it
  local tmp_decrypt
  tmp_decrypt=$(mktemp)
  # if ! suppresses set -e, letting us handle openssl failure gracefully
  if ! printf '%s\n' "$ciphertext" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -base64 -pass pass:"$password" > "$tmp_decrypt" 2>/dev/null; then
    rm -f "$tmp_decrypt"
    echo "Error: Decryption failed. Wrong password or corrupted data." >&2
    return 1
  fi
  result=$(cat "$tmp_decrypt")
  rm -f "$tmp_decrypt"
  echo "$result"
}

# Cleanup function: removes secrets file unless .keep file exists
# No cleanup needed in FD mode (file descriptor auto-closes)
# No cleanup needed in source mode (no file written when loading from keyring)
cleanup() {
  if [[ "$use_fd" == "false" ]]; then
    # Delete if user opted to store in keyring, or if it's a temporary file without .keep
    if [[ "$delete_local_file_after" == "true" ]] || [[ -f "$secrets_file" && ! -e "${secrets_file}.keep" ]]; then
      rm -f "$secrets_file"
      info "✓ $secrets_file deleted after run"
    fi
  fi
}

# Validate that a command was provided
if [[ $# -eq 0 ]]; then
  echo "Error: No command provided. Use --help for usage information." >&2
  exit 1
fi

# Auto-detect @SECRETS@ token in arguments to enable FD mode
for arg in "$@"; do
  if [[ "$arg" == *"@SECRETS@"* ]]; then
    use_fd=true
    break
  fi
done

# Setup cleanup trap to remove temporary secrets file on exit
trap cleanup EXIT INT TERM

# If secrets file already exists locally, ask user if they want to store it in keyring
# Skip this check when using file descriptors, as we'll provide via /dev/fd/9
if [[ "$use_fd" == "false" ]] && [[ -f "$secrets_file" ]]; then
  info "ℹ Found existing local file: $secrets_file"
  read -p "Store this file in the keyring for app='$app_name'? (y/n) " -n 1 -r
  echo  # New line after response
  
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Read the file content and store in keyring
    secrets_content="$(cat "$secrets_file")"
    label="Secrets for $app_name"
    
    if [[ "$plaintext_mode" == "true" ]]; then
      # Store plaintext (opt-out mode)
      secrets_to_store="$secrets_content"
      store_key="$app_name"
    else
      # Default: encrypt
      if ! resolve_encrypt_password; then
        echo "Error: No password available for encryption. Use --plaintext to disable encryption, set SECRET_TOOL_PASSWORD, or pass --password=PASSWORD." >&2
        exit 1
      fi
      check_openssl
      secrets_to_store=$(encrypt_secrets "$secrets_content")
      store_key="${app_name}-encrypted"
    fi
    
    if echo "$secrets_to_store" | secret-tool store --label "$label" app "$store_key"; then
      if [[ "$store_key" == "${app_name}-encrypted" ]]; then
        info "✓ Stored in keyring as '$label' (encrypted)"
      else
        info "✓ Stored in keyring as '$label' (warning: not encrypted)"
      fi
      delete_local_file_after=true
    else
      echo "Error: Failed to store secrets in keyring. Using local file instead." >&2
    fi
  fi
  
  # If we didn't store in keyring, just use the file directly
  if [[ "$delete_local_file_after" == "false" ]]; then
    if [[ "$source_mode" == "true" ]]; then
      source_and_export "$secrets_file"
      info "→ Sourced into environment + Running: $*"
    else
      info "→ Running: $*"
    fi
    SECRETS_FILE="$secrets_file" "$@"
    exit $?
  fi
fi

# Load secrets from keyring
if [[ "$use_fd" == "true" ]]; then
  info "Loading secrets for app='$app_name' (FD mode via @SECRETS@ - no disk I/O)..."
elif [[ "$source_mode" == "true" ]]; then
  info "Loading secrets for app='$app_name' (source mode - no file written)..."
else
  info "Loading secrets for app='$app_name' → $secrets_file..."
fi

# Check for required dependency
if ! command -v secret-tool >/dev/null 2>&1; then
  echo "Error: secret-tool not found. Please install libsecret-tools:" >&2
  echo "  Fedora/RHEL: sudo dnf install libsecret-tools" >&2
  echo "  Ubuntu/Debian: sudo apt install libsecret-tools" >&2
  echo "  Arch: sudo pacman -S libsecret" >&2
  exit 127
fi

# Try to load secrets from keyring
secrets_content=""
encrypted_key="${app_name}-encrypted"

# Phase 1: Try encrypted key first (skip if --plaintext is active)
if [[ "$plaintext_mode" == "false" ]] && secrets_content=$(secret-tool lookup app "$encrypted_key" 2>/dev/null) && [[ -n "$secrets_content" ]]; then
  if ! resolve_decrypt_password; then
    echo "Error: Encrypted entry found but no password available. Use --password=PASSWORD or set SECRET_TOOL_PASSWORD." >&2
    exit 1
  fi
  check_openssl
  if ! secrets_content=$(decrypt_secrets "$secrets_content"); then
    exit 1
  fi
  
  line_count=$(echo "$secrets_content" | wc -l)
  if [[ "$use_fd" == "true" ]]; then
    info "✓ Loaded from keyring (encrypted, $line_count lines)"
  elif [[ "$source_mode" == "true" ]]; then
    info "✓ Loaded from keyring (encrypted, $line_count lines, source mode — no file written)"
  else
    echo "$secrets_content" > "$secrets_file"
    chmod 600 "$secrets_file"
    info "✓ Loaded from keyring (encrypted, $(wc -l < "$secrets_file") lines)"
  fi

# Phase 2: Fallback to plaintext key
elif secrets_content=$(secret-tool lookup app "$app_name" 2>/dev/null) && [[ -n "$secrets_content" ]]; then
  if [[ "$plaintext_mode" == "false" ]]; then
    info "ℹ Found plaintext entry for app='$app_name' — not encrypted"
  fi
  
  line_count=$(echo "$secrets_content" | wc -l)
  if [[ "$use_fd" == "true" ]]; then
    info "✓ Loaded from keyring ($line_count lines, not encrypted)"
  elif [[ "$source_mode" == "true" ]]; then
    info "✓ Loaded from keyring ($line_count lines, source mode — no file written, not encrypted)"
  else
    echo "$secrets_content" > "$secrets_file"
    chmod 600 "$secrets_file"
    info "✓ Loaded from keyring ($(wc -l < "$secrets_file") lines, not encrypted)"
  fi

# Phase 3: No secrets found — prompt user to provide them
else
	info "⚠ No secrets found for app='$app_name' in keyring."
	info "Paste your secrets content (KEY=VALUE format), then press Ctrl-D to finish:"
	info "(Press Ctrl-C to cancel)"
	
	secrets_input="$(cat)"
	
	if [[ -z "$secrets_input" ]]; then
		echo "Error: No secrets provided. Aborting." >&2
		exit 1
	fi
	
	label="Secrets for $app_name"
	store_key="$app_name"
	secrets_to_store="$secrets_input"
	is_encrypted=false
	
	# Determine if we should encrypt before storing
	if [[ "$plaintext_mode" == "true" ]]; then
	  store_key="$app_name"
	  secrets_content="$secrets_input"
	else
	  if ! resolve_encrypt_password; then
	    echo "Error: No password available for encryption. Use --plaintext to disable encryption, set SECRET_TOOL_PASSWORD, or pass --password=PASSWORD." >&2
	    exit 1
	  fi
	  check_openssl
	  secrets_to_store=$(encrypt_secrets "$secrets_input")
	  store_key="$encrypted_key"
	  is_encrypted=true
	  secrets_content="$secrets_input"  # Keep plaintext for use
	fi
	
	if echo "$secrets_to_store" | secret-tool store --label "$label" app "$store_key"; then
	  if [[ "$is_encrypted" == "true" ]]; then
	    # Already have plaintext from encryption step
	    line_count=$(echo "$secrets_content" | wc -l)
	    
	    if [[ "$use_fd" == "true" ]]; then
	      info "✓ Stored in keyring as '$label' ($line_count lines, encrypted)"
	    elif [[ "$source_mode" == "true" ]]; then
	      info "✓ Stored in keyring as '$label' ($line_count lines, encrypted, source mode — no file written)"
	    else
	      echo "$secrets_content" > "$secrets_file"
	      chmod 600 "$secrets_file"
	      info "✓ Stored in keyring as '$label' ($(wc -l < "$secrets_file") lines, encrypted)"
	    fi
	  else
	    # Retrieve from keyring to verify plaintext store
	    if secrets_content=$(secret-tool lookup app "$store_key" 2>/dev/null); then
	      line_count=$(echo "$secrets_content" | wc -l)
	      
	      if [[ "$use_fd" == "true" ]]; then
	        info "✓ Stored in keyring as '$label' ($line_count lines, not encrypted)"
	      elif [[ "$source_mode" == "true" ]]; then
	        info "✓ Stored in keyring as '$label' ($line_count lines, source mode — no file written, not encrypted)"
	      else
	        echo "$secrets_content" > "$secrets_file"
	        chmod 600 "$secrets_file"
	        info "✓ Stored in keyring as '$label' ($(wc -l < "$secrets_file") lines, not encrypted)"
	      fi
	    else
	      echo "Error: Failed to retrieve secrets from keyring. Aborting." >&2
	      exit 1
	    fi
	  fi
	else
		echo "Error: Failed to store secrets in keyring. Aborting." >&2
		exit 1
	fi
fi

# Execute the command with SECRETS_FILE environment variable
if [[ "$use_fd" == "true" ]]; then
  # Replace @SECRETS@ tokens with /dev/fd/9 and execute with FD mode
  declare -a modified_args=()
  for arg in "$@"; do
    modified_args+=("${arg//@SECRETS@//dev/fd/9}")
  done

  # Source into environment when --source is used (via process substitution, no disk I/O)
  if [[ "$source_mode" == "true" ]]; then
    set -a
    source <(echo "$secrets_content")
    set +a
    info "→ Sourced into environment (from keyring, no disk I/O)"
  fi

  info "→ Running: ${modified_args[*]}"
  # Open FD 9 for reading from secrets content (using heredoc to avoid ps exposure)
  exec 9< <(cat <<< "$secrets_content")
  SECRETS_FILE="/dev/fd/9" "${modified_args[@]}"
  exec_status=$?
  # Close the file descriptor
  exec 9<&-
  exit $exec_status
else
  if [[ "$source_mode" == "true" ]]; then
    # Source directly from keyring content in memory — no temp file written
    set -a
    source <(echo "$secrets_content")
    set +a
    info "→ Sourced into environment (from keyring, no disk I/O) + Running: $*"
    "$@"
  else
    # Use file mode - traditional temp file approach
    info "→ Running: $*"
    SECRETS_FILE="$secrets_file" "$@"
  fi
fi
