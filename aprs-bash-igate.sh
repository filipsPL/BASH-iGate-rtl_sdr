#!/bin/bash

# Get the directory where the script is located, regardless of where it's called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the configuration file using the absolute path
source "$SCRIPT_DIR/aprs-bash-igate.conf"

# Check if the configuration file was loaded successfully
if [ $? -ne 0 ]; then
    echo "Error: Failed to load configuration file from $SCRIPT_DIR/aprs-bash-igate.conf"
    exit 1
fi

# comment for logging in and for initial welcome message
COMMENT="BASH-iGate-rtl_sdr 0.2"

# Initialize message counter
MESSAGE_COUNT=0
UNBUF_CMD="stdbuf -o0 -e0 -i0"

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

    # Start RTL-SDR and multimon-ng pipeline and process the output
    # Filter out RFONLY lines and only include APRS lines
    $UNBUF_CMD rtl_fm -f 144800000 -s 22050 -o 4 -p 1 | $UNBUF_CMD multimon-ng -a AFSK1200 -A -t raw - | $UNBUF_CMD grep -E '^APRS: ' | $UNBUF_CMD grep -v "RFONLY" | while read line; do
        # Extract APRS packet (removing the "APRS: " prefix)
        packet="${line#APRS: }"

        # Send to APRS-IS
        echo "$packet" >&3

        # Increment message counter
        ((MESSAGE_COUNT++))
        echo "[$(date +"%F %T")] [#$MESSAGE_COUNT] $packet"

        # Small delay to avoid flooding - optional for high traffic
        # sleep 0.07
    done

    # probably we will not reach this point

    # Display final count before exit (note: this may not execute due to pipeline)
    echo "Total messages processed: $MESSAGE_COUNT"

    # Close connection
    exec 3>&-
    echo "Reconnecting if needed"

done
