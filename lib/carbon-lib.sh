#!/bin/sh
#
# Setup Environment and Declare functions for Graphite
# enabled shell scripting
#
# Override Defaults with /etc/sysconfig/carbon-endpoint
#
# To see debugging information, export CARBON_DEBUG=1
# To see additional information, export CARBON_DEBUG=2
#
# To use, source this file, then add metrics:
#
#  add_metric "simple.key $value";
#  # Send your metrics at the end:
#  send_to_carbon;
#
#  add_metrics will prepend "${CARBON_BASE}.${HOST}" to the
#  metric name.
#
# When send_to_carbon is called, the timestamp is added to the messages.
#
# Brad Lhotsky <brad.lhotsky@gmail.com>

#------------------------------------------------------------------------#
# Carbon Server Configuration
CARBON_HOST="graphite"
CARBON_PORT="2003"
CARBON_BASE="tmp"

# Read in System Config
if [ -f "/etc/sysconfig/carbon-endpoint" ]; then
    . /etc/sysconfig/carbon-endpoint
fi

if [ -z $CARBON_SEND ]; then
    CARBON_SEND="enabled"
fi;

# Caching
CARBON_CACHE="/tmp/cache.carbon"
declare -r CARBON_CACHE
CARBON_STASH="$CARBON_CACHE/stash.$$.$EUID"
declare -r CARBON_STASH

if [ ! -d "$CARBON_CACHE" ]; then
    mkdir "$CARBON_CACHE";
    chmod 0777 "$CARBON_CACHE";
fi;

#------------------------------------------------------------------------#
# Cleanup
if [ -f "$CARBON_STASH" ] && [ -O "$CARBON_STASH" ]; then
    rm -f "$CARBON_STASH" 2> /dev/null;
fi;
find "$CARBON_CACHE" -type f -user $(whoami) -mtime +1 -exec rm -f {} \; 2> /dev/null

#------------------------------------------------------------------------#
# Constants
HOST=`hostname -s`
declare -r HOST
RUN_TIME=`date +%s`
declare -r RUN_TIME
[[ $CARBON_DEBUG -gt 1 ]] && echo "Env: HOST=$HOST, CARBON_STASH=$CARBON_STASH";

#------------------------------------------------------------------------#
# Function Declarations
function add_metric() {
    echo "${CARBON_BASE}.${HOST}.$1 $RUN_TIME" >> "$CARBON_STASH";
    (( $CARBON_DEBUG )) && echo $1;
}

function send_to_carbon() {
    if [ "$CARBON_SEND" != "disabled" ]; then
        nc "$CARBON_HOST" "$CARBON_PORT" < "$CARBON_STASH";
        [[ $CARBON_DEBUG -gt 1 ]] && cat "$CARBON_STASH";
    fi;
    rm -f "$CARBON_STASH";
}
