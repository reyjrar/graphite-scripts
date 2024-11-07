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
CARBON_LIB=${CARBON_LIB:=/usr/local/lib/carbon-lib.sh}
if [ -e "$CARBON_LIB" ]; then
    . "$CARBON_LIB"
else
    echo "unable to load $CARBON_LIB";
    exit 1;
fi;

if [ -z $CARBON_NO_SPLAY ]; then
    # Splay to spread out updates
    SPLAY=$(( $RANDOM % 10 ));
    (( $CARBON_DEBUG )) && echo -n "* Splay for this run is $SPLAY seconds, sleeping ..";
    sleep $SPLAY;
    (( $CARBON_DEBUG )) && echo " resuming";
fi;

#------------------------------------------------------------------------#
# Pre Check Routines
# Hard Disk Monitoring
disk_prefixes=( 'sd' 'hd' 'c0d' 'c1d' 'nvme' )
declare -r disks_prefixes

#------------------------------------------------------------------------#
# Globals
declare -a disks
CACHE_DISKS="$CARBON_CACHE/disks";
if [ -f "$CACHE_DISKS" ]; then
    . $CACHE_DISKS;
fi;

#------------------------------------------------------------------------#
# Disk Discovery
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
        echo "disks='${disks[@]}'" > "$CACHE_DISKS";
    fi;
fi;
(( $CARBON_DEBUG )) && echo "disk_check found: ${disks[@]}";

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
if [ -x /usr/bin/mpstat ]; then
    S_TIME_FORMAT=ISO /usr/bin/mpstat -P ALL |grep '^[0-9]' | grep -v CPU | while read line; do
        set -- $line;
        cpu=$2;

        add_metric "cpu.${cpu}.user $3";
        add_metric "cpu.${cpu}.nice $4";
        add_metric "cpu.${cpu}.system $5";
        add_metric "cpu.${cpu}.iowait $6";
        add_metric "cpu.${cpu}.irq $7";
        add_metric "cpu.${cpu}.soft $8";
        add_metric "cpu.${cpu}.steal $9";
        add_metric "cpu.${cpu}.guest ${10}";
        add_metric "cpu.${cpu}.gnice ${11}";
        add_metric "cpu.${cpu}.idle ${12}";
    done;
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
# Use Free -b to get memory details
/usr/bin/free -b | while read line; do
    set -- $line;
    k=`echo $1 | tr [A-Z] [a-z] | sed -e s/://`;
    if [ "$k" != "mem" ] && [ "$k" != "swap" ]; then
        continue
    fi
    add_metric "memory.$k.total $2";
    add_metric "memory.$k.used $3";
    add_metric "memory.$k.free $4";
    [ ! -z $5 ] && add_metric "memory.$k.shared $5";
    [ ! -z $6 ] && add_metric "memory.$k.buffers $6";
    [ ! -z $7 ] && add_metric "memory.$k.cached $7";
done;
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
df -Pl -x tmpfs -B1 | while read line; do
    set -- $line;

    dev=$1;
    total=$2;
    used=$3;
    available=$4;
    percentage=$5;
    path_orig=$6;

    if [[ "$dev" =~ "/dev" ]]; then
        case "$path_orig" in
                "/")    path="slash";;
            "/boot")    path="boot";;
                  *)    tmp=${6:1}; path=${tmp//\//_};;
        esac;
        add_metric "fs.$path.total $total";
        add_metric "fs.$path.used $used";
        add_metric "fs.$path.available $available";
    fi;
done;
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
tcp_stats=$(mktemp)
/bin/netstat -s --tcp > $tcp_stats
    grep 'connections* opening' $tcp_stats| while read line; do
        set -- $line;
        add_metric "tcp.connections.$2 $1";
    done;
    tcp_failed=`grep 'failed connection attempts' $tcp_stats|awk '{print $1}'`;
    add_metric "tcp.connections.failed $tcp_failed";
    # Grab TCP Reset Data
    grep reset $tcp_stats|grep -v due |awk '{print $1 " " $NF}' | while read line; do
        set -- $line;
        add_metric "tcp.resets.$2 $1";
    done;
rm -f $tcp_stats;
# Grab UDP Packet Data
/bin/netstat -s --udp|grep packets|grep -v unknown | while read line; do
    set -- $line;
    add_metric "udp.packets.$3 $1";
done;

#------------------------------------------------------------------------#
# Advanced Network Stats
cat /proc/net/snmp |sed -e 's/://'|while read line; do
    if [ -z "$header" ]; then
        read -a header <<< $( echo $line );
        # remote the first element
        header=("${header[@]:1}")
        continue;
    else
        read -a data <<< $( echo $line );
        class=$( echo ${data[0]} | tr [A-Z] [a-z] );
        data=("${data[@]:1}")
        for v in "${data[@]}"; do
            k="${header[0]}"
            header=("${header[@]:1}")
            add_metric "netstat.$class.$k $v";
        done
    fi
done

#------------------------------------------------------------------------#
# SEND THE UPDATES TO CARBON
send_to_carbon;
exit 0;
