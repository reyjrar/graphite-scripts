#!/bin/sh
#
# Setup Environment and Declare functions for Graphite
# enabled shell scripting
#
# To see debugging information, export DEBUG=1
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

# Caching
CARBON_STASH="/tmp/carbon_stash.$$"
CACHE_DISKS="/tmp/cache.monitor.disks"

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
declare -a metrics
declare -a disks

#------------------------------------------------------------------------#
# Function Declarations
function add_metric() {
    metrics[${#metrics[*]}]="${CARBON_BASE}.${HOST}.$1";
    (( $DEBUG )) && echo $1;
}

function send_to_carbon() {
    [ -f "$CARBON_STASH" ] && rm -f $CARBON_STASH;

    for metric in "${metrics[@]}"; do
        echo "$metric $RUN_TIME" >> $CARBON_STASH; 
    done;

    nc $CARBON_HOST $CARBON_PORT < $CARBON_STASH;
    rm -f $CARBON_STASH;
}

function find_disks_to_check() {
    if [ -f "$CACHE_DISKS" ]; then
        . $CACHE_DISKS;
    fi;

    if [ ${#disks} -gt 0 ]; then
        (( $DEBUG )) && echo "disk_check: retrieved from cache";
    else
        if [ -f /proc/partitions ]; then
            while read line
            do
                disk=`echo $line |awk '{print $4}'`;
                for prefix in "${disk_prefixes[@]}"; do
                    if [ "X$disk" == "X" ]; then
                        continue;
                    fi;
                    matched=`expr match $disk $prefix`;
                    (( $DEBUG )) && echo " => check: expr match $disk $prefix : $matched";
                    if [ $matched -gt 0 ]; then
                        disks[${#disks[*]}]="$disk";
                        (( $DEBUG )) && echo "DISK: $disk";
                        break
                    fi;
                done;
            done < /proc/partitions;
            # Cache
            echo "disks='${disks[@]}'" > $CACHE_DISKS;
        fi;
    fi;

    (( $DEBUG )) && echo "disk_check found: ${disks[@]}";
}
