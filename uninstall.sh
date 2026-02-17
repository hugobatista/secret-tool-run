#!/bin/bash
set -euo pipefail

# vaultsh uninstaller
# Removes vaultsh installation and optionally cleans up keyring entries

# Colors for output
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
	GREEN="$(tput setaf 2)"
	YELLOW="$(tput setaf 3)"
	RED="$(tput setaf 1)"
	CYAN="$(tput setaf 6)"
	BOLD="$(tput bold)"
	RESET="$(tput sgr0)"
else
	GREEN=""
	YELLOW=""
	RED=""
	CYAN=""
	BOLD=""
	RESET=""
fi

info() {
	echo "${CYAN}➜${RESET} $*"
}

success() {
	echo "${GREEN}✓${RESET} $*"
}

warning() {
	echo "${YELLOW}⚠${RESET} $*"
}

error() {
	echo "${RED}✗${RESET} $*" >&2
}

header() {
	echo ""
	echo "${BOLD}${CYAN}$*${RESET}"
	echo ""
}

header "vaultsh Uninstaller"

# Detect installation locations
SYSTEM_PATH="/usr/local/bin/vaultsh"
USER_PATH="$HOME/.local/bin/vaultsh"
FOUND_LOCATIONS=()

if [[ -f "$SYSTEM_PATH" ]]; then
	FOUND_LOCATIONS+=("$SYSTEM_PATH")
fi

if [[ -f "$USER_PATH" ]]; then
	FOUND_LOCATIONS+=("$USER_PATH")
fi

# Check if vaultsh is installed
if [[ ${#FOUND_LOCATIONS[@]} -eq 0 ]]; then
	error "vaultsh not found in common installation locations:"
	echo "  - $SYSTEM_PATH"
	echo "  - $USER_PATH"
	echo ""
	info "You may need to manually remove vaultsh if it's installed elsewhere."
	exit 1
fi

# Show found installations
info "Found vaultsh installation(s):"
for location in "${FOUND_LOCATIONS[@]}"; do
	echo "  • $location"
done
echo ""

# Confirm removal
read -p "${BOLD}Remove vaultsh from these location(s)?${RESET} (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
	error "Uninstallation cancelled"
	exit 1
fi

# Remove installations
for location in "${FOUND_LOCATIONS[@]}"; do
	info "Removing $location..."
	
	# Check if we need sudo
	if [[ "$location" == /usr/* ]] || [[ "$location" == /opt/* ]]; then
		if sudo rm -f "$location"; then
			success "Removed $location"
		else
			error "Failed to remove $location"
		fi
	else
		if rm -f "$location"; then
			success "Removed $location"
		else
			error "Failed to remove $location"
		fi
	fi
done

# Verify removal
if command -v vaultsh >/dev/null 2>&1; then
	warning "vaultsh is still in PATH"
	warning "You may need to open a new terminal or run: hash -r"
else
	success "vaultsh removed from PATH"
fi

# Offer to clean up keyring entries
echo ""
header "Keyring Cleanup (Optional)"

echo "vaultsh may have stored secrets in your system keyring."
echo "Would you like to see what's stored?"
echo ""
read -p "List vaultsh keyring entries? (y/N) " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
	if ! command -v secret-tool >/dev/null 2>&1; then
		warning "secret-tool not found - cannot list keyring entries"
	else
		info "Searching for vaultsh entries in keyring..."
		echo ""
		
		# Try to list entries with app attribute
		if secret-tool search app "" 2>/dev/null | grep -q "attribute.app"; then
			echo "${BOLD}Found keyring entries:${RESET}"
			secret-tool search app "" 2>/dev/null | grep -A2 "attribute.app" || true
			echo ""
			echo "To remove a specific entry, use:"
			echo "  ${BOLD}secret-tool clear app \"your-app-name\"${RESET}"
			echo ""
			echo "Example:"
			echo "  ${BOLD}secret-tool clear app \"myproject\"${RESET}"
			echo ""
			
			read -p "Would you like help removing entries? (y/N) " -n 1 -r
			echo
			if [[ $REPLY =~ ^[Yy]$ ]]; then
				echo ""
				read -p "Enter the app name to remove (or leave empty to skip): " app_name
				if [[ -n "$app_name" ]]; then
					info "Removing keyring entry for app='$app_name'..."
					if secret-tool clear app "$app_name" 2>/dev/null; then
						success "Removed entry for '$app_name'"
					else
						warning "No entry found for '$app_name' or removal failed"
					fi
				else
					info "Skipping keyring cleanup"
				fi
			fi
		else
			success "No vaultsh entries found in keyring"
		fi
	fi
fi

echo ""
header "Uninstallation Complete"
echo ""
echo "vaultsh has been removed from your system."
echo ""
echo "If you kept secrets in the keyring, you can still access them with:"
echo "  ${BOLD}secret-tool search app \"\"${RESET}          # List all"
echo "  ${BOLD}secret-tool lookup app \"app-name\"${RESET}  # View specific"
echo "  ${BOLD}secret-tool clear app \"app-name\"${RESET}   # Remove specific"
echo ""
success "Thank you for using vaultsh! 👋"
