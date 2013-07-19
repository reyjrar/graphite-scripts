#!/usr/bin/env perl

use strict;
use warnings;

BEGIN {
    delete $ENV{$_} for qw(http_proxy https_proxy);
};

use JSON;
use LWP::Simple qw( get );
use IO::Socket::INET;
use Getopt::Long;
use Pod::Usage;

#------------------------------------------------------------------------#
# Argument Collection
my %opt;
GetOptions(\%opt,
    'format:s',
    'carbon-base:s',
    'carbon-proto:s',
    'carbon-server:s',
    'carbon-port:i',
    'host:s',
    'local',
    'underscores',
    'help|h',
    'manual|m',
    'verbose|v',
    'debug|d',
);

#------------------------------------------------------------------------#
# Documentations!
pod2usage(1) if $opt{help};
pod2usage(-exitstatus => 0, -verbose => 2) if $opt{manual};

#------------------------------------------------------------------------#
# Host or Local
pod2usage(1) if !$opt{local} and !$opt{host};

#------------------------------------------------------------------------#
# Argument Sanitazation
my %_formats = (
    carbon      => 'graphite',
    graphite    => 'graphite',
    cacti       => 'cacti',
);
 # Force graphite if carbon-server specified
if( exists $opt{'carbon-server'} and length $opt{'carbon-server'} ) {
    $opt{format} = 'graphite';
}
# Validate Format
if( exists $opt{format} and length $opt{format} ) {
    if( exists $_formats{$opt{format}} ) {
        $opt{format} = $_formats{$opt{format}};
    }
    else {
        delete $opt{format};
    }
}
# Merge options into config
my %cfg = (
    format => 'graphite',
    'carbon-proto' => 'tcp',
    'carbon-base'  => 'general.es',
    %opt,
);

#------------------------------------------------------------------------#
# Format Routines
my $time = time;
my $HOSTNAME = undef;
my %_formatter = (
    cacti       => sub {
            local $_ = shift;
            my $name = shift;
            s/\./_/g;
            s/\s/:/;
            s/$/\n/;
            $_;
    },
    graphite    => sub {
            local $_ = shift;
            my $hostname = $HOSTNAME;
            if (exists $opt{underscores} && $opt{underscores}) {
              $hostname =~ s/\./_/g;
            }
            s/^/$cfg{'carbon-base'}.$hostname./;
            s/$/ $time\n/;
            $_;
    },
);

#------------------------------------------------------------------------#
# Carbon Socket Creation
my $carbon_socket;
if( exists $cfg{'carbon-server'} and length $cfg{'carbon-server'} ) {
    my %valid_protos = ( tcp => 1, udp => 1 );
    die "invalid protocol specified: $cfg{'carbon-proto'}\n" unless exists $valid_protos{$cfg{'carbon-proto'}};
    $carbon_socket = IO::Socket::INET->new(
        PeerAddr    => $cfg{'carbon-server'},
        PeerPort    => $cfg{'carbon-port'} || 2003,
        Proto       => $cfg{'carbon-proto'},
    );
    die "unable to connect to carbon server: $!" unless defined $carbon_socket && $carbon_socket->connected;
}

#------------------------------------------------------------------------#
# Collect and Decode the Cluster Statistics
my @stats = qw(http os jvm process transport);
my $qs = join('&', map { "$_=true" } @stats );
my $url = exists $opt{local} && $opt{local}
        ? "http://localhost:9200/_cluster/nodes/_local/stats?$qs"
        : "http://$opt{host}:9200/_cluster/nodes/stats?$qs";
my $json = get($url);
my $data = JSON->new->decode( $json );
my $node_data = parse_stats( $data );

#------------------------------------------------------------------------#
# Send output to appropriate channels
foreach my $stat ( @{ $node_data } ) {
    my $output = format_output( $stat );
    if( defined $carbon_socket && $carbon_socket->connected) {
        $carbon_socket->send( $output );
        print STDERR $output if $cfg{verbose};
    }
    else {
        print $output;
    }
}


#------------------------------------------------------------------------#
# Generate Node Statistics Hash
sub parse_stats {
    my $data = shift;

    my $node_id;
    my @nodes;
    foreach my $id (keys %{ $data->{nodes} }) {
        if( (exists $opt{local} and $opt{local} ) || $data->{nodes}{$id}{name} eq $cfg{host}  ) {
            $node_id = $id;
            $HOSTNAME=$data->{nodes}{$id}{name};
            last;
        }
        else {
            push @nodes, $data->{nodes}{$id}{name};
        }
    }
    die "no information found for $cfg{host}, nodes found: ", join(', ', @nodes), "\n" unless exists $data->{nodes}{$node_id};
    my $node = $data->{nodes}{$node_id};

    my @stats = ();
    # Index Details
    push @stats,
        # Basic Stats
        "indices.size $node->{indices}{store}{size_in_bytes}",
        "indices.docs $node->{indices}{docs}{count}",
        # Indexing
        "indices.indexing.total $node->{indices}{indexing}{index_total}",
        "indices.indexing.total_ms $node->{indices}{indexing}{index_time_in_millis}",
        "indices.indexing.delete $node->{indices}{indexing}{delete_total}",
        "indices.indexing.delete_ms $node->{indices}{indexing}{delete_time_in_millis}",
         # Get Data
        "indices.get.total $node->{indices}{get}{total}",
        "indices.get.total_ms $node->{indices}{get}{time_in_millis}",
        "indices.get.exists $node->{indices}{get}{exists_total}",
        "indices.get.exists_ms $node->{indices}{get}{exists_time_in_millis}",
        "indices.get.missing $node->{indices}{get}{missing_total}",
        "indices.get.missing_ms $node->{indices}{get}{missing_time_in_millis}",
        # Search Data
        "indices.search.query $node->{indices}{search}{query_total}",
        "indices.search.query_ms $node->{indices}{search}{query_time_in_millis}",
        "indices.search.fetch $node->{indices}{search}{fetch_total}",
        "indices.search.fetch_ms $node->{indices}{search}{fetch_time_in_millis}",
        # Search Data
        "indices.cache.field_evictions $node->{indices}{fielddata}{evictions}",
        "indices.cache.field_size $node->{indices}{fielddata}{memory_size_in_bytes}",
        "indices.cache.filter_evictions $node->{indices}{filter_cache}{evictions}",
        "indices.cache.filter_size $node->{indices}{filter_cache}{memory_size_in_bytes}",
        # Merges
        "indices.merges.total_docs $node->{indices}{merges}{total_docs}",
        "indices.merges.total_size $node->{indices}{merges}{total_size_in_bytes}",
        "indices.merges.total_ms $node->{indices}{merges}{total_time_in_millis}",
        # Refresh
        "indices.refresh.total $node->{indices}{refresh}{total}",
        "indices.refresh.total_ms $node->{indices}{refresh}{total_time_in_millis}",
        # Flush
        "indices.flush.total $node->{indices}{flush}{total}",
        "indices.flush.total_ms $node->{indices}{flush}{total_time_in_millis}",
        ;

    # Transport Details
    push @stats,
        "transport.rx_bytes $node->{transport}{rx_size_in_bytes}",
        "transport.rx_count $node->{transport}{rx_count}",
        "transport.tx_bytes $node->{transport}{tx_size_in_bytes}",
        "transport.tx_count $node->{transport}{tx_count}",
        "transport.server_open $node->{transport}{server_open}",
        ;
    # HTTP Details
    push @stats,
        "http.open $node->{http}{current_open}",
        "http.total $node->{http}{total_opened}",
        ;
    # JVM Garbage Collectors;
    push @stats,
        "jvm.gc.count $node->{jvm}{gc}{collection_count}",
        "jvm.gc.time_ms $node->{jvm}{gc}{collection_time_in_millis}",
        ;
    foreach my $collector (keys %{ $node->{jvm}{gc}{collectors} } ) {
        my $col = $node->{jvm}{gc}{collectors}{$collector};
        my $prefix = "jvm.gc.collector.$collector";
        push @stats,
            "$prefix.count $col->{collection_count}",
            "$prefix.time_ms $col->{collection_time_in_millis}",
            ;
    }
    # JVM Memory Usage
    my %_mem = ( used_bytes => 'used_in_bytes', committed_bytes => 'committed_in_bytes' );
    foreach my $heap (qw(heap non_heap)) {
        while( my ($gm,$em) = each %_mem ) {
            my $val = $node->{jvm}{mem}{"${heap}_${em}"};
            push @stats,
                "jvm.mem.$heap.$gm $val";
        }
    }
    # JVM Threads
    push @stats,
        "jvm.threads $node->{jvm}{threads}{count}",
        ;
    # OS Information
    push @stats,
        "process.openfds $node->{process}{open_file_descriptors}",
        ;
    return \@stats;
}

#------------------------------------------------------------------------#
# Formatters
sub format_output {
    my $line = shift;
    if( exists $_formatter{$cfg{format}} ) {
        return $_formatter{$cfg{format}}->( $line );
    }
    else {
        warn "call to undefined formatter($cfg{format})";
        return "$line\n";
    }
}


__END__

=head1 NAME

perf_elastic_search.pl - Check Elastic Search Performance

=head1 SYNOPSIS

perf_elastic_search.pl --format=graphite --host [host] [options]

Options:

    --help              print help
    --manual            print full manual
    --local             Poll localhost and use name reported by ES
    --host|-H           Host to poll for statistics
    --format            stats Format (graphite or cacti) (Default: graphite)
    --carbon-base       The prefix to use for carbon metrics (Default: general.es)
    --carbon-server     Send Graphite stats to Carbon Server (Automatically sets format=graphite)
    --carbon-port       Port for to use for Carbon (Default: 2003)
    --carbon-proto      Protocol for to use for Carbon (Default: tcp)
    --verbose           Send additional messages to STDERR
    --underscores       Send hostname as host_name to graphite instead of those pesky dots

=head1 OPTIONS

=over 8

=item B<help>

Print this message and exit

=item B<manual>

Print this message and exit

=item B<local>

Optional, check local host (if not specified, --host required)

=item B<host>

Optional, the host to check (if not specified --local required)

=item B<format>

stats format:

    graphite        Use format for graphite/carbon (default)
    cacti           For use with Cacti

=item B<carbon-base>

The prefix to use for metrics sent to carbon.  The default is "general.es".  Please note, the host name
of the ElasticSearch node will be appended, followed by the metric name.

=item B<carbon-server>

Send stats to the carbon server specified.  This automatically forces --format=graphite
and does not produce stats on STDOUT

=item B<carbon-port>

Use this port for the carbon server, useless without --carbon-server

=item B<verbose>

Verbose stats, to not interfere with cacti, output goes to STDERR

=back

=head1 DESCRIPTION

This is a plugin to poll elasticsearch for performance data and stats it in a relevant
format for your monitoring infrastructure.

=head1 AUTHOR

Brad Lhotsky <brad.lhotsky@gmail.com>

=cut
