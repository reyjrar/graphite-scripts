#!/bin/sh
#
# Gather Statistics from Linux Systems and
# and send them to graphite.  Cron this to run
# as often as you'd like.
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
CARBON_STASH="/tmp/carbon_stash"
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
}

function send_to_carbon() {
    [ -f "$CARBON_STASH" ] && rm -f $CARBON_STASH;

    for metric in "${metrics[@]}"; do
        echo "$metric $RUN_TIME" >> $CARBON_STASH; 
    done;

    nc $CARBON_HOST $CARBON_PORT < $CARBON_STASH;
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

#------------------------------------------------------------------------#
# Pre Check Routines
find_disks_to_check;
# Remove Old Cache Files
find /tmp -name cache.monitor.* -mtime +2 -exec {} \;

#------------------------------------------------------------------------#
# Load Average
if [ -f /proc/loadavg ]; then
    declare -a load
    for i in `cut -d' ' -f 1-3 /proc/loadavg`; do
        load[${#load[*]}]="$i";
    done;
    add_metric "load.1min ${load[0]}";
    add_metric "load.5min ${load[1]}";
    add_metric "load.15min ${load[2]}";
else
    : # Code to rely on uptime
fi;
#------------------------------------------------------------------------#
# CPU Stats
if [ -f /proc/stat ]; then
    while read line; do
        set -- $line;
        var=$1;

        if [[ "$var" =~ "^cpu" ]]; then
            add_metric "stat.${var}.user $2";
            add_metric "stat.${var}.nice $3";
            add_metric "stat.${var}.system $4";
            add_metric "stat.${var}.idle $5";
            add_metric "stat.${var}.iowait $6";
            add_metric "stat.${var}.irq $7";
            add_metric "stat.${var}.softirq $8";
        elif [ "$var" == "procs_running" ]; then
            add_metric "stat.$var $2";
        elif [ "$var" == "procs_blocked" ]; then
            add_metric "stat.$var $2";
        elif [ "$var" == "ctxt" ]; then
            add_metric "stat.context_switches $2";
        fi;
    done < /proc/stat;
fi;
# IO Stats
iostat_line=`iostat |awk 'FNR==4'`;
rc=$?;
if [ $rc -eq 0 ]; then
    set -- $iostat_line;
    add_metric "iostat.user $1";
    add_metric "iostat.nice $2";
    add_metric "iostat.system $3";
    add_metric "iostat.iowait $4";
    add_metric "iostat.steal $5";
    add_metric "iostat.idle $6";
fi;
#------------------------------------------------------------------------#
# Memory Information
if [ -f /proc/meminfo ]; then
    while read line
    do
        field=`echo $line |cut -d: -f 1`;
        value=`echo $line |cut -d' ' -f 2`;
        value=$(( value * 1024 ));
        add_metric "meminfo.$field $value";
    done < /proc/meminfo;
fi;
# Virtual Memory
if [ -f /proc/vmstat ]; then
    while read line
    do
        field=`echo $line |cut -d' ' -f 1`;
        value=`echo $line |cut -d' ' -f 2`;
        add_metric "vmstat.$field $value";
    done < /proc/vmstat;
else
    : # Code to rely on vmstat binary
# Memory Information
fi;

#------------------------------------------------------------------------#
# Disk Performance Information
if [ ${#disks} -gt 0 ]; then
    if [ -f /proc/diskstats ]; then
        while read line; do
            set -- $line;
            if [[ "${disks[@]}" =~ "$3" ]]; then
                add_metric "disks.$3.read.issued $4";
                add_metric "disks.$3.read.merged $5";
                add_metric "disks.$3.read.sectors $6";
                add_metric "disks.$3.read.ms $7";
                add_metric "disks.$3.write.complete $8";
                add_metric "disks.$3.write.merged $9";
                add_metric "disks.$3.write.sectors ${10}";
                add_metric "disks.$3.write.ms ${11}";
                add_metric "disks.$3.io.current ${12}";
                add_metric "disks.$3.io.ms ${13}";
                add_metric "disks.$3.io.weighted_ms ${14}";
            fi;
        done < /proc/diskstats;
    fi;
fi;
# File System Data
df -l -x tmpfs > /tmp/cache.monitors.df;
while read line; do
    set -- $line;

    dev=$1;
    total=$2;
    used=$3;
    available=$4;
    percentage=$5;
    path_orig=$6;

    if [[ "$dev" =~ "^\/dev" ]]; then
        case "$path_orig" in
                "/")    path="slash";;
            "/boot")    path="boot";;
                  *)    tmp=${6:1}; path=${tmp//\//_};;
        esac;
        add_metric "fs.$path.total $total";
        add_metric "fs.$path.used $used";
        add_metric "fs.$path.available $available";
    fi;
done < /tmp/cache.monitors.df;
rm -f /tmp/cache.monitors.df;
#------------------------------------------------------------------------#
# SEND THE UPDATES TO CARBON
send_to_carbon;
exit 0;
