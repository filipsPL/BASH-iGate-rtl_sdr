#!/bin/bash

# comment for logging in and for initial welcome message
COMMENT="BASH-iGate-rtl_sdr 0.22"
URL="https://github.com/filipsPL/BASH-iGate-rtl_sdr 2025.04.18"

RECONNECT_TIME="30m"      # reconnect every... (see: man timeout) in case something is wrong with
SAVE_MESSAGES_EVERY_S=600 # save every statistics to file every ...  seconds

cat <<EOF

░█▀▄░█▀█░█▀▀░█░█░░░░░▀█▀░█▀▀░█▀█░▀█▀░█▀▀
░█▀▄░█▀█░▀▀█░█▀█░▄▄▄░░█░░█░█░█▀█░░█░░█▀▀
░▀▀░░▀░▀░▀▀▀░▀░▀░░░░░▀▀▀░▀▀▀░▀░▀░░▀░░▀▀▀

Super simple iGate for bash/linux
which makes use of rtl_sdr and multimon_ng

                           by Filip SP5FLS

EOF

set -o pipefail #  the exit status of the pipeline will be the exit status of the rightmost command to exit with a non-zero status, or zero if all commands exit successfully.
export TERM=xterm-256color

# Get the directory where the script is located, regardless of where it's called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# dir with stats
STATS_DIR="$SCRIPT_DIR/stats"

# Create stats directory if it doesn't exist
mkdir -p "$STATS_DIR"

# ------------------------------------------------------------------------------------------------------------ #

# Source the configuration file using the absolute path
source "$SCRIPT_DIR/aprs-bash-igate.conf"

# Check if the configuration file was loaded successfully
if [ $? -ne 0 ]; then
    echo "Error: Failed to load configuration file from $SCRIPT_DIR/aprs-bash-igate.conf"
    exit 1
fi

# Check if rtl_fm and multimon-ng are installed
if ! command -v rtl_fm &>/dev/null; then
    echo "Error: rtl_fm is not installed. Please install it."
    exit 1
fi

if ! command -v multimon-ng &>/dev/null; then
    echo "Error: multimon-ng is not installed. Please install it."
    exit 1
fi

# ------------------------------------------------------------------------------------------------------------ #

# Initialize message counter
MESSAGE_COUNT=0
MESSAGE_COUNT_DIFF=0
UNBUF_CMD="stdbuf -o0 -e0 -i0"

# ------------------------------------------------------------------------------------------------------------ #

# Function to save statistics to file
save_stats() {
    STAT_FILE="$STATS_DIR/$(date +"%F")_packages_count.csv"
    echo "[$(date +"%F %T")] **** Saving statistics to file every ${SAVE_MESSAGES_EVERY_S}s: handled $MESSAGE_COUNT_DIFF messages"

    # if STAT_FILE doesn't exist, create it
    if [ ! -f "$STAT_FILE" ]; then
        echo "Date,msg_count" >"$STAT_FILE"
    fi
    echo "$(date +"%F %T"),$MESSAGE_COUNT_DIFF" >>$STAT_FILE
}

# Function to handle signals - saves stats before exit
handle_exit() {
    echo "[$(date +"%F %T")] Received termination signal. Saving statistics..."

    # Save current hour stats
    save_stats
    exit 0
}

# Register signal handlers
trap handle_exit SIGINT SIGTERM

# ------------------------------------------------------------------------------------------------------------ #

colorize() {
    # If no regex is provided, just pass through
    if [[ -z "$COLORSTRING" ]]; then
        $UNBUF_CMD cat
    else
        # Default to red if no color specified
        $UNBUF_CMD cat | $UNBUF_CMD ack --flush --color-match=green --passthru "$COLORSTRING"
    fi
}

# ------------------------------------------------------------------------------------------------------------ #

while :; do
    # Connect to APRS-IS
    exec 3<>/dev/tcp/$SERVER/$PORT

    # Login to APRS-IS
    echo "user $USERNAME pass $PASSCODE vers $COMMENT filter $FILTER" >&3
    # Read login response
    read -t 5 response <&3
    echo "Server response: $response"

    # Send initial position report
    TIMESTAMP=$(date +"%d%H%M")z # Current day, hour, minute followed by z
    POSITION_PACKET="$CALLSIGN>APRS,qAS,$USERNAME:@${TIMESTAMP}${LATITUDE}/${LONGITUDE}${SYMBOL}${COMMENT}"
    echo "$POSITION_PACKET" >&3
    echo "[$(date +"%F %T")] Sent position: $POSITION_PACKET"

    UPTIME=$(uptime -p)
    STATUS_PACKET="$CALLSIGN>APRS,qAS,$USERNAME:>Uptime: ${UPTIME}"
    echo "$STATUS_PACKET" >&3
    echo "[$(date +"%F %T")] Sent status: $STATUS_PACKET"

    URL_PACKET="$CALLSIGN>APRS,qAS,$USERNAME:>$URL"
    echo "$URL_PACKET" >&3
    echo "[$(date +"%F %T")] Sent status: $URL_PACKET"

    START_TIME=$(date +%s)

    # Start RTL-SDR and multimon-ng pipeline and process the output
    # Filter out RFONLY lines and only include APRS lines
    # if ! timeout "$RECONNECT_TIME" $UNBUF_CMD rtl_fm -f 144800000 -s 22050 -o 4 -p 1 | $UNBUF_CMD multimon-ng -a AFSK1200 -A -t raw - | $UNBUF_CMD grep -E '^APRS: ' | $UNBUF_CMD grep -v "RFONLY" | while read line; do
    if ! timeout "$RECONNECT_TIME" $UNBUF_CMD rtl_fm -f 144800000 -s 22050 -o 4 -p 1 | $UNBUF_CMD multimon-ng -a AFSK1200 -A -t raw - | $UNBUF_CMD grep -E '^APRS: ' | $UNBUF_CMD grep -v "RFONLY" | while read line; do
        # Extract APRS packet (removing the "APRS: " prefix)
        packet="${line#APRS: }"

        # Send to APRS-IS
        echo "$packet" >&3

        # Increment message counter
        ((MESSAGE_COUNT++))
        ((MESSAGE_COUNT_DIFF++))

        # save every number of messages:
        # ((MESSAGE_COUNT_DIFF++))
        # if ((MESSAGE_COUNT % 10 == 0)); then
        #     save_stats
        #     MESSAGE_COUNT_DIFF=0
        # fi

        # Save stats every SAVE_MESSAGES_EVERY_S seconds
        CURRENT_TIME=$(date +%s)
        TIME_DELTA=$((CURRENT_TIME - START_TIME))
        if [ "$TIME_DELTA" -ge "$SAVE_MESSAGES_EVERY_S" ]; then
            save_stats
            # Reset the start time and counter
            START_TIME=$CURRENT_TIME
            MESSAGE_COUNT_DIFF=0
            break
        fi

        # printing the packet info
        $UNBUF_CMD echo -e "[$(date +"%F %T")] [#$MESSAGE_COUNT] $packet" #| colorize

    done; then
        echo "[$(date +"%F %T")] Pipeline failed with exit code $?" >&2

        # Close connection
        exec 3>&-
        # A small delay before reconnecting
        sleep 5
        continue
    fi

    # Close connection
    exec 3>&-
    echo "Reconnecting if needed"

done

# Remove the stats pipe
rm -f "$MESSAGE_PIPE"
