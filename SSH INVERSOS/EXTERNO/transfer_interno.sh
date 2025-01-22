#!/usr/bin/expect -f

# Default values for parameters
set BACKUP_FILE [lindex $argv 0]
set BACKUP_DIR [lindex $argv 1]
set LOCAL_PASSWORD [lindex $argv 2]
set PORT [lindex $argv 3]
set LOCAL_PATH [lindex $argv 4]

# Set default values if not provided
if {$BACKUP_DIR == ""} {set BACKUP_DIR "/backups/oracle/temp"}
if {$LOCAL_PASSWORD == ""} {set LOCAL_PASSWORD "admin.prueba/2015*"}
if {$PORT == ""} {set PORT "2222"}
if {$LOCAL_PATH == ""} {set LOCAL_PATH "/var/backups/back_cabildo"}

# Configuration
set timeout -1
set LOG_DIR "./log/envio"
set LOG_FILE "$LOG_DIR/transfer_[clock format [clock seconds] -format %Y%m%d_%H%M%S].log"

# Create log directory if it doesn't exist
if {![file exists $LOG_DIR]} {
    file mkdir $LOG_DIR
}

# Logging procedure
proc log_message {message} {
    set timestamp [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    set log_message "$timestamp - $message"
    
    # Display in console
    puts $log_message
    
    # Save to log file
    if [catch {
        set fd [open $::LOG_FILE "a"]
        puts $fd $log_message
        close $fd
    } error] {
        puts "Error writing to log file: $error"
    }
}

# Parameter validation
if {$BACKUP_FILE == ""} {
    log_message "Error: Backup file parameter is required"
    exit 1
}

log_message "=== Starting new transfer process ==="
log_message "File to transfer: $BACKUP_FILE"
log_message "Source path: $BACKUP_DIR"
log_message "Destination path: $LOCAL_PATH"

# Check if remote file exists
log_message "Verifying file existence on remote server..."
spawn ssh -p $PORT \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o HostKeyAlgorithms=+ssh-rsa \
    -o KexAlgorithms=+diffie-hellman-group14-sha1 \
    root@localhost \
    "test -f '$BACKUP_DIR/$BACKUP_FILE' && echo 'EXISTS' || echo 'NOT_EXISTS'"

expect {
    -re "(?i)password:" {
        send "$LOCAL_PASSWORD\r"
        exp_continue
    }
    "EXISTS" {
        log_message "File found on remote server"
    }
    "NOT_EXISTS" {
        log_message "Error: File $BACKUP_DIR/$BACKUP_FILE does not exist on remote server"
        exit 1
    }
    timeout {
        log_message "Error: Timeout while verifying file existence"
        exit 1
    }
    eof {
        # Check the spawn_id status
        if {[string length [wait]] == 0} {
            log_message "Error: SSH connection failed"
            exit 1
        }
    }
}

# File transfer with retries
set MAX_RETRIES 3
set retry 0
set transfer_success 0

while {$retry < $MAX_RETRIES && !$transfer_success} {
    log_message "Transfer attempt [expr $retry + 1] of $MAX_RETRIES"
    
    spawn rsync -avz --progress \
        -e "ssh -p $PORT \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o HostKeyAlgorithms=+ssh-rsa \
            -o KexAlgorithms=+diffie-hellman-group14-sha1" \
        root@localhost:"$BACKUP_DIR/$BACKUP_FILE" \
        "$LOCAL_PATH/"

    expect {
        -re "(?i)password:" {
            send "$LOCAL_PASSWORD\r"
            exp_continue
        }
        "100%" {
            set transfer_success 1
        }
        timeout {
            log_message "Warning: Transfer timeout. Retrying..."
            incr retry
            continue
        }
        eof {
            # Check if transfer was successful
            if {[string length [wait]] == 0} {
                log_message "Warning: Transfer failed. Retrying..."
                incr retry
                continue
            } else {
                set transfer_success 1
            }
        }
    }
}

if {!$transfer_success} {
    log_message "Error: Transfer failed after $MAX_RETRIES attempts"
    exit 1
}

# Verify transferred file
if {![file exists "$LOCAL_PATH/$BACKUP_FILE"]} {
    log_message "Error: File not found in destination after transfer"
    exit 1
}

log_message "Transfer completed successfully"
log_message "=== Transfer process finished ==="
exit 0