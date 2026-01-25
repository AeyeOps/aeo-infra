#!/bin/bash
# SSH Configuration Management
# Manages ~/.ssh/config entries for VMs

# Add SSH config entry for a VM
add_ssh_config_entry() {
    local name="${1:-$VM_NAME}"
    local ip="${2:-$VM_IP}"
    local user="${3:-$VM_USER}"
    local config_file="${HOME}/.ssh/config"

    # Ensure .ssh directory exists
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"

    # Check if entry already exists
    if grep -q "^Host ${name}\$" "$config_file" 2>/dev/null; then
        echo "  SSH config entry for '$name' already exists"
        return 0
    fi

    # Add entry
    cat >> "$config_file" << EOF

# VM: ${name} (added by vm.sh)
Host ${name}
    HostName ${ip}
    User ${user}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF

    chmod 600 "$config_file"
    echo "  ✓ Added SSH config entry for '$name' → $ip"
}

# Remove SSH config entry for a VM
remove_ssh_config_entry() {
    local name="${1:-$VM_NAME}"
    local config_file="${HOME}/.ssh/config"

    if [[ ! -f "$config_file" ]]; then
        return 0
    fi

    # Create temp file without the entry
    local temp_file
    temp_file=$(mktemp)

    awk -v name="$name" '
        /^# VM:/ { in_block = 0 }
        /^Host / {
            if ($2 == name) {
                in_block = 1
                # Skip the comment line before Host if it exists
                if (prev_line ~ /^# VM:/) {
                    prev_line = ""
                }
            } else {
                in_block = 0
            }
        }
        !in_block {
            if (prev_line != "") print prev_line
            prev_line = $0
        }
        END { if (prev_line != "" && !in_block) print prev_line }
    ' "$config_file" > "$temp_file"

    mv "$temp_file" "$config_file"
    chmod 600 "$config_file"
    echo "  Removed SSH config entry for '$name'"
}

# Show SSH config status
show_ssh_config_status() {
    local name="${1:-$VM_NAME}"
    local ip="${2:-$VM_IP}"

    echo "Host Config"

    if check_ssh_config_entry "$name"; then
        print_check 1 "SSH config: Host $name → $ip"
    else
        print_check 0 "SSH config: no entry for '$name'"
    fi
}

# Wait for SSH to become accessible, showing serial output
wait_for_ssh() {
    local name="${1:-$VM_NAME}"
    local max_attempts="${2:-30}"
    local serial_log="${VM_SERIAL_LOG:-/run/shm/qemu-${name}.serial}"
    local ssh_status_file="/tmp/.ssh-wait-$$"

    echo "Waiting for SSH (showing boot output, Ctrl+C to skip)..."
    echo "────────────────────────────────────────────────────────"

    # Background: poll SSH silently, write status when done
    (
        local attempt=1
        while [[ $attempt -le $max_attempts ]]; do
            if check_ssh_accessible "$name"; then
                echo "connected" > "$ssh_status_file"
                exit 0
            fi
            ((attempt++))
            sleep 2
        done
        echo "timeout" > "$ssh_status_file"
    ) &
    local poll_pid=$!

    # Foreground: tail serial log until SSH poll completes
    if [[ -f "$serial_log" ]]; then
        # Tail until the status file appears (SSH connected or timeout)
        tail -f "$serial_log" 2>/dev/null &
        local tail_pid=$!

        # Wait for background SSH poll to finish
        wait "$poll_pid" 2>/dev/null

        # Kill the tail
        kill "$tail_pid" 2>/dev/null
        wait "$tail_pid" 2>/dev/null
    else
        # No serial log, just wait for SSH poll
        wait "$poll_pid" 2>/dev/null
    fi

    echo ""
    echo "────────────────────────────────────────────────────────"

    # Check result
    if [[ -f "$ssh_status_file" ]]; then
        local status
        status=$(cat "$ssh_status_file")
        rm -f "$ssh_status_file"
        if [[ "$status" == "connected" ]]; then
            echo "  ✓ SSH connected!"
            return 0
        fi
    fi

    echo "  ✗ SSH not accessible after $max_attempts attempts"
    return 1
}

# Ensure SSH config entry exists
ensure_ssh_config() {
    local name="${1:-$VM_NAME}"
    local ip="${2:-$VM_IP}"
    local user="${3:-$VM_USER}"

    if ! check_ssh_config_entry "$name"; then
        add_ssh_config_entry "$name" "$ip" "$user"
    fi
}
