package Seco::Maint::Helper;

use strict;
use IO::Socket;
use Carp;
use Exporter;

our (@EXPORT, %EXPORT_TAGS, $VERSION);

$VERSION = '0.1.0';
@ISA = qw /Exporter/;
@EXPORT_OK = qw /GetGauge/;
%EXPORT_TAGS = (all => [@EXPORT_OK], common => [@EXPORT_OK]);
@EXPORT = qw /GetGauge/;

use vars qw($AltPath);

($AltPath) = grep (-d, qw(
  /home/seco/tools/conf
));

# --------------------------------------------------------------------------- #
# "public" methods                                                            #
# --------------------------------------------------------------------------- #

sub GetConfInfo {
  my($file, %info, $line);

  $file = $_[0];

  unless( -f "$file") {
    die "ERROR: no such file '$file'";
  }

  if( open( CONF, "$file") == 0) {
     die "ERROR: could not open file '$file' $!";
  }

  while( defined( $line = <CONF>)) {
    next if( $line =~ /^\s*#/);
    $line =~ s/(#.*)//;
    if ( $line =~ /\s*(\S+)\s+(.*)/) {
       $info{$1} = $2;
    }
  }
  close CONF;

  return %info;
}

sub GetNetInfo {
  my ($cluster) = $_[0];
  my ($type, $full, $key);
  my ($file, $info, $dir);
 
  if ($cluster =~ /(.*):(.*)/) {
    $full = $cluster;
    $cluster = $1;
    $type = $2;
  }

  ($dir) = grep(-f "$_/net.cf",(
    "/home/seco/tools/conf/$cluster",
    "$AltPath/$cluster/tools/conf",
    "$AltPath/$cluster"));

  $dir ||= "/home/seco/tools/conf/$cluster";
  unless (-d $dir) {
    die "ERROR: no cluster directory found at '$dir'";
  }  

  $file = "$dir/net.cf";
  %info = GetConfInfo($file);

  if ( defined($type) ) {
    foreach $key (keys %info) {
      if (defined($info{"$key:$type"})) {
        $info{$key} = $info{"$key:$type"};
      }
    }
  }

  return %info;
}

sub GetGauge {

  my ($cluster, $grep, $alarm, $mode) = @_;
  my @return;
  my $line;
  my %info = GetNetInfo($cluster);
  my ($host, $port) = split (/:/, $info{GAUGE});
  ($port) = split(/,/$port);
  my $remote;

  $port += 2000 if ((defined $mode) && 
                    ($mode =~ m/^(fast|1)/i));

  $remote = IO::Socket::INET->new(
    Proto=>"tcp",
    PeerAddr=>$host,
    PeerPort=>$port,
    Timeout=>($alarm ? $alarm : 10));
  unless ($remote) {
    die "Unable to connect to $host port $port: $!\n";
  }

  alarm $alarm if ($alarm);
  while ($line = <$remote>) {
    chomp $line
    $line =~ s/\s+/:/g;
    push (@return, $line) if ($line =~ /$grep/);
    last if ($line =~ /^T:\d+/);
    last if ($line =~ /^#MM:/);
  } 
  close $remote;

  alarm(0) if ($alarm);

  return @return; 
   
}

1;

__END__

=pod

=head1 NAME

Seco::Maint::Helper - basic routines imported from /home/seco/tools/lib/Seco.pm

  use Seco::Maint::Helper;

  # return gauge data for a particular cluster
  my @gauge = GetGauge($cluster, $grep, $alarm, $mode);

=head1 AUTHOR

Jumbo Admin <jumbo-admin@inktomi.com>

=cut
