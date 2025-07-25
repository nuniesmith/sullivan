#!/bin/bash

# Docker Update Cron Monitor Script
# Use this to check the status and logs of your automated Docker updates

LOG_FILE="/home/jordan/sullivan/docker_update.log"
SCRIPT_PATH="/home/jordan/sullivan/scripts/update_docker.sh"

log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $1"
}

show_status() {
  echo "=== Docker Update Cron Job Status ==="
  echo
  echo "Cron Schedule:"
  crontab -l | grep update_docker.sh || echo "No Docker update cron job found!"
  echo
  
  echo "Script Location:"
  if [ -f "$SCRIPT_PATH" ]; then
    echo "✅ Script exists: $SCRIPT_PATH"
    echo "   Permissions: $(ls -la "$SCRIPT_PATH" | awk '{print $1}')"
  else
    echo "❌ Script not found: $SCRIPT_PATH"
  fi
  echo
  
  echo "Log File:"
  if [ -f "$LOG_FILE" ]; then
    echo "✅ Log file exists: $LOG_FILE"
    echo "   Size: $(du -h "$LOG_FILE" | cut -f1)"
    echo "   Last modified: $(stat -c %y "$LOG_FILE")"
  else
    echo "📝 Log file will be created on first run: $LOG_FILE"
  fi
}

show_recent_logs() {
  echo "=== Recent Docker Update Logs (Last 50 lines) ==="
  if [ -f "$LOG_FILE" ]; then
    tail -50 "$LOG_FILE"
  else
    echo "No log file found yet. The cron job hasn't run or failed to create the log."
  fi
}

show_last_run() {
  echo "=== Last Successful Update ==="
  if [ -f "$LOG_FILE" ]; then
    grep "Docker container update process completed successfully" "$LOG_FILE" | tail -1 || echo "No successful updates found in logs"
  else
    echo "No log file found yet."
  fi
}

test_script() {
  echo "=== Testing Docker Update Script ==="
  log "INFO: Running Docker update script in test mode..."
  
  if [ -f "$SCRIPT_PATH" ]; then
    echo "Testing script permissions and basic functionality..."
    "$SCRIPT_PATH" help
  else
    echo "❌ Script not found: $SCRIPT_PATH"
    return 1
  fi
}

case "${1:-status}" in
  "status")
    show_status
    ;;
  "logs")
    show_recent_logs
    ;;
  "last")
    show_last_run
    ;;
  "test")
    test_script
    ;;
  "tail")
    echo "=== Following Docker Update Logs (Ctrl+C to exit) ==="
    if [ -f "$LOG_FILE" ]; then
      tail -f "$LOG_FILE"
    else
      echo "No log file found yet. Creating it and waiting..."
      touch "$LOG_FILE"
      tail -f "$LOG_FILE"
    fi
    ;;
  "help")
    echo "Docker Update Cron Monitor"
    echo "Usage: $0 [status|logs|last|test|tail|help]"
    echo
    echo "Commands:"
    echo "  status  - Show cron job status and file information (default)"
    echo "  logs    - Show recent log entries"
    echo "  last    - Show last successful update"
    echo "  test    - Test the update script"
    echo "  tail    - Follow the log file in real-time"
    echo "  help    - Show this help message"
    ;;
  *)
    echo "Unknown option: $1. Use 'help' for usage information."
    exit 1
    ;;
esac
