#!/bin/sh
#
# Wrapper around a shell script to time it to Graphite
#
# Brad Lhotsky <brad.lhotsky@gmail.com>
#

#------------------------------------------------------------------------#
# Arguement Processing
args=("$@");
command=$1;
unset args[0];
timings_file="/tmp/timinigs.$$";

#------------------------------------------------------------------------#
# Load Caron Library
if [ -e /usr/local/lib/carbon-lib.sh ]; then
    . /usr/local/lib/carbon-lib.sh
else
    ${args[@]};
    exit $?;
fi;

#------------------------------------------------------------------------#
# Execute the Command, capturing the RC
(( $DEBUG )) && echo "($command) ${args[@]} to $timings_file";
/usr/bin/time -o $timings_file -f "user:%U\nsys:%S\nreal:%e\ncpu:%P" "${args[@]}";
RC=$?;

#------------------------------------------------------------------------#
# Only log successful commands
if [[ $RC != 0 ]]; then
    rm $timings_file;
    exit $RC;
fi;

#------------------------------------------------------------------------#
# Read the file, add the metrics
while read line; do
    # Skip "Command exitted with" lines
    if [[ "$line" =~ 'exit' ]]; then
        continue;
    fi
    k=`echo $line |cut -d: -f1`;
    vraw=`echo $line |cut -d: -f2`;
    # Strip the % from the CPU line
    v=${vraw/\%/};
    # Add the Metric
    add_metric "commands.$command.$k $v"
done < $timings_file;
rm $timings_file;

#------------------------------------------------------------------------#
# Send this to carbon
send_to_carbon;
