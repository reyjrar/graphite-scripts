#!/bin/sh
#
# Gather Statistics from Linux Systems and
# and send them to graphite.  Cron this to run
# as often as you'd like.
#
# Brad Lhotsky <brad.lhotsky@gmail.com>
#
#------------------------------------------------------------------------#
# Load Carbon Lib
if [ -e /usr/local/lib/carbon-lib.sh ]; then
    . /usr/local/lib/carbon-lib.sh
else
    echo "unable to load /usr/local/lib/carbon-lib.sh";
    exit 1;
fi;

if [ -z $CARBON_NO_SPLAY ]; then
    # Splay to spread out updates
    SPLAY=$(( $RANDOM % 20 ));
    (( $CARBON_DEBUG )) && echo -n "* Splay for this run is $SPLAY seconds, sleeping ..";
    sleep $SPLAY;
    (( $CARBON_DEBUG )) && echo " resuming";
fi;

#------------------------------------------------------------------------#
# Pre Check Routines
find_disks_to_check;

#------------------------------------------------------------------------#
# Load Average
if [ -f /proc/loadavg ]; then
    load=`cat /proc/loadavg`;
    set -- $load;
    add_metric "load.1min $1";
    add_metric "load.5min $2";
    add_metric "load.15min $3";
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
                disk=$3
                disk=${disk/\//_};
                add_metric "disks.$disk.read.issued $4";
                add_metric "disks.$disk.read.merged $5";
                add_metric "disks.$disk.read.sectors $6";
                add_metric "disks.$disk.read.ms $7";
                add_metric "disks.$disk.write.complete $8";
                add_metric "disks.$disk.write.merged $9";
                add_metric "disks.$disk.write.sectors ${10}";
                add_metric "disks.$disk.write.ms ${11}";
                add_metric "disks.$disk.io.current ${12}";
                add_metric "disks.$disk.io.ms ${13}";
                add_metric "disks.$disk.io.weighted_ms ${14}";
            fi;
        done < /proc/diskstats;
    fi;
fi;
# File System Data
df -Pl -x tmpfs > /tmp/cache.monitors.df;
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
# Network Statistics
for nic in `/sbin/route -n |grep -v Kernel|grep -v Gateway|awk '{print $8}'|sort -u`; do
    (( $CARBON_DEBUG )) && echo "Fetching interface statistics for $nic";
    /sbin/ifconfig $nic |grep packets| while read line; do
        set -- $line;
        direction=`echo $1|tr '[A-Z]' '[a-z]'`;
        tmp=($@); fields=(${tmp[@]:1});
        for statistic in "${fields[@]}"; do
            k=`echo $statistic|cut -d: -f 1`;
            v=`echo $statistic|cut -d: -f 2`;
            add_metric "nic.$nic.$direction.$k $v";
        done;
    done;
    /sbin/ifconfig $nic |grep bytes| while read line; do
        set -- $line;
        rx_bytes=`echo $2 | cut -d: -f 2`;
        tx_bytes=`echo $6 | cut -d: -f 2`;
        add_metric "nic.$nic.rx.bytes $rx_bytes";
        add_metric "nic.$nic.tx.bytes $tx_bytes";
    done;
    collisions=`/sbin/ifconfig $nic |grep collisions|awk '{print $1}'|cut -d: -f2`;
    add_metric "nic.$nic.collisions $collisions";
done;
# Grab TCP Connection Data
/bin/netstat -s --tcp |grep 'connections* opening' | while read line; do
    set -- $line;
    add_metric "tcp.connections.$2 $1";
done;
tcp_failed=`/bin/netstat -s --tcp |grep 'failed connection attempts'|awk '{print $1}'`;
add_metric "tcp.connections.failed $tcp_failed";
# Grab TCP Reset Data
/bin/netstat -s --tcp |grep reset|grep -v due |awk '{print $1 " " $NF}' | while read line; do
    set -- $line;
    add_metric "tcp.resets.$2 $1";
done;
# Grab UDP Packet Data
/bin/netstat -s --udp|grep packets|grep -v unknown | while read line; do
    set -- $line;
    add_metric "udp.packets.$3 $1";
done;
#------------------------------------------------------------------------#
# SEND THE UPDATES TO CARBON
send_to_carbon;
exit 0;
