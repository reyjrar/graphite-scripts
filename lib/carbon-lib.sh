#!/bin/sh
#
# Setup Environment and Declare functions for Graphite
# enabled shell scripting
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
CARBON_STASH="$CARBON_CACHE/stash.$$"
declare -r CARBON_STASH

if [ ! -d "$CARBON_CACHE" ]; then
    mkdir $CARBON_CACHE;
fi;

#------------------------------------------------------------------------#
# Cleanup
[ -f "$CARBON_STASH" ] && rm -f $CARBON_STASH;
find $CARBON_CACHE -type f -mtime +1 -exec rm {} \;

#------------------------------------------------------------------------#
# Constants
HOST=`hostname -s`
declare -r HOST
RUN_TIME=`date +%s`
declare -r RUN_TIME
# Hard Disk Monitoring
disk_prefixes=( 'sd' 'hd' 'c0d' 'c1d' )
declare -r disks_prefixes

#------------------------------------------------------------------------#
# Globals
declare -a disks

#------------------------------------------------------------------------#
# Function Declarations
function add_metric() {
    echo "${CARBON_BASE}.${HOST}.$1 $RUN_TIME" >> $CARBON_STASH;
    (( $CARBON_DEBUG )) && echo $1;
}

function send_to_carbon() {
    if [ $CARBON_SEND != "disabled" ]; then
        nc $CARBON_HOST $CARBON_PORT < $CARBON_STASH;
        [[ $CARBON_DEBUG -gt 1 ]] && cat $CARBON_STASH;
    fi;
    rm -f $CARBON_STASH;
}

function find_disks_to_check() {
    CACHE_DISKS="$CARBON_CACHE/disks";
    if [ -f "$CACHE_DISKS" ]; then
        . $CACHE_DISKS;
    fi;

    if [ ${#disks} -gt 0 ]; then
        (( $CARBON_DEBUG )) && echo "disk_check: retrieved from cache";
    else
        if [ -f /proc/partitions ]; then
            while read line
            do
                disk=`echo $line |awk '{print $4}'`;
                for prefix in "${disk_prefixes[@]}"; do
                    [ -z "$disk" ] && continue;

                    (( $CARBON_DEBUG )) && echo " => check: '$disk' =~ '$prefix' : $matched";
                    if [[ "$disk" =~ "$prefix" ]]; then
                        disks[${#disks[*]}]="$disk";
                        (( $CARBON_DEBUG )) && echo "DISK: $disk";
                        break
                    fi;
                done;
            done < /proc/partitions;
            # Cache
            echo "disks='${disks[@]}'" > $CACHE_DISKS;
        fi;
    fi;

    (( $CARBON_DEBUG )) && echo "disk_check found: ${disks[@]}";
}
