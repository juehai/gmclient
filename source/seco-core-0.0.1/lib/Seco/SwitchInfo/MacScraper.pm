package Seco::SwitchInfo::MacScraper;

# Walks a Catalyst switch and returns a map of
# MAC addresses to their respective ports.

use strict;
use warnings;

use Net::SNMP;


our %oid = (
            # maps the last 5 OID digits into MAC w/ dot1dTpFdbPort
            dot1dTpFdbAddress     => '.1.3.6.1.2.1.17.4.3.1.1',
            # maps the last 5 OID digits into bridge ports w/ dot1dTpFdbAddress
            dot1dTpFdbPort        => '.1.3.6.1.2.1.17.4.3.1.2',
            # maps bridge ports to interface indexes
            dot1dBasePortIfIndex  => '.1.3.6.1.2.1.17.1.4.1.2',
            # maps interface indexes to interface names
            ifName                => '.1.3.6.1.2.1.31.1.1.1.1',
            # returns all active vlans
            vtpVlanState          => '1.3.6.1.4.1.9.9.46.1.3.1.1.2',
            # blah
            sysUpTime             => '1.3.6.1.2.1.1.3.0',
            );

our $community = 'westside';


# two calling styles:
# MacScraper->new("host")
# MacScraper->new({-switch => val})

sub new {
    my ($class, $opt) = @_;
    my %opts;
    if (ref $opt eq 'HASH') {
        %opts = %$opt;
    } else {
        $opts{-switch} = $opt;
    }
    my $self = \%opts;
    $self->{-community} ||= $community;
    my @vlans = keys %{_get_table($self->{-switch},
                                  $self->{-community},
                                  $oid{vtpVlanState})};
    warn "time: ".time." after gotten vlans" if $self->{-debug};
    s/^.*\.// for @vlans;
    $self->{vlans} = \@vlans; # vlans enabled on this switch
                              # we will need to iterate each one to build our maps
    my $maps = {};
    my $byvlan = {};
    foreach my $vlan (@vlans) {
        warn "time: ".time." starting $vlan" if $self->{-debug};
        foreach my $oid ( qw/ dot1dTpFdbAddress
                              dot1dTpFdbPort
                              dot1dBasePortIfIndex
                              ifName
                          /) {
            my $new = _get_table( $self->{-switch},
                                  "$community\@$vlan",
                                  $oid{$oid}
                                );
            warn "bad read for vlan: $vlan oid: $oid on ".$self->{-switch}
              if ref $new ne 'HASH' and $self->{debug};

            # merge all vlan tables by map type
            while (my ($k, $v) = each %$new) {
                if ($oid eq 'dot1dTpFdbAddress' or
                    $oid eq 'dot1dTpFdbPort') {
                    # only want last 5 segments of oid to associate
                    $k =~ /\.(\d+\.\d+\.\d+\.\d+\.\d+)$/
                      or die "unknown snmp response for oid: $oid vlan: $vlan";
                    $k = $1;
                } elsif ($oid eq 'ifName' or
                           $oid eq 'dot1dBasePortIfIndex') {
                    # need the last segment to associate
                    $k =~ /\.(\d+)$/
                      or die "unknown snmp response for oid: $oid vlan: $vlan";
                    $k = $1;
                }
                $maps->{$oid}{$k} = $v;
                $byvlan->{$vlan}{$oid}{$k} = $v;
            }
        }
    }

    warn "time: ".time." just before if2mac assoc" if $self->{-debug};
    # We now have the 4 maps between MAC and swport.
    # let's associate them.
    # swports may contain more than one MAC.

    my %if2mac;
    while (my ($oid, $mac) = each %{$maps->{dot1dTpFdbAddress}}) {
        push( @{ $if2mac{ $maps->{ifName}{
                             $maps->{dot1dBasePortIfIndex}{
                                 $maps->{dot1dTpFdbPort}{$oid}
                             }
                          }
                        }
               },
              $mac
            );
    }
    warn "time: ".time." just after if2mac assoc" if $self->{-debug};
    $self->{if2mac} = \%if2mac;
    $self->{maps} = $maps; # probably don't need this, storing anyway
    $self->{byvlan} = $byvlan;
    return bless $self, $class;
}

# dump the entire switch port to mac address table
# each ifname maps to a list of macs
sub allmacs {
    my ($self) = @_;
    return $self->{if2mac};
}

# Dump what we believe to be only hosts (one MAC per iface)
# only one mac per ifname in the returned hash
sub hostmacs {
    my ($self) = @_;
    my %ret;
    while (my ($k, $v) = each %{$self->{if2mac}}) {
        $ret{$k} = $v->[0] if @$v == 1;
    }
    return \%ret;
}

# return a hashref of the OID => values for that table
sub _get_table {
    my ($host, $community, $oid) = @_;
    my ($snmp, $snmp_err) = Net::SNMP->session(
                                               -hostname  => $host,
                                               -community => $community,
                                               -port      => 161,
                                              ) or return undef;
    return undef unless defined $snmp;
    return $snmp->get_table( -baseoid => $oid );
}

1;


__END__

=pod

=head1 NAME

Seco::MacScraper - Scrape MAC addresses from Cisco Catalyst leaf switches

=head1 SYNOPSIS

  use Seco::MacScraper;

  my $switch = Seco::MacScraper->new("c2970-46.sci");
  my $map = $switch->allmacs;
  while (my ($port, $macs) = each %$map) {
    print "Port $port has [ @$macs ]";
  }

  $map = $switch->hostmacs;
  while (my ($port, $mac) = each %$map) {
      print "Port $port has $mac";
  }

=head1 DESCRIPTION

B<Seco::MacScraper> is used to associate MAC addresses with switch
ports. Scraping is done via SNMP, and takes place during object instantiation.

=head1 METHODS

=over 4

=item B<new>

C<new> create a new Seco::MacScraper, and populate it with information
from a specified switch. Takes either a switch hostname, or a hashref with
various arguments:

-switch => Mandantory, hostname of switch to scrape
-debug  => Turn on extra debugging output

Expect instantiation to take around 30 seconds due to multiple SNMP queries
that take place.

=item B<allmacs>

C<allmacs> returns a hashref mapping port names to a list of macs on each port.

=item B<hostmacs>

C<hostmacs> erturns a hashref mapping port names to singular MAC address values.
Ports containing more than one MAC are assumed to be links and are ignored.

=back

=head1 EXAMPLES

=head2 see synopsis.

=head1 AUTHOR

  Evan Miller <eam@yahoo-inc.com>

=cut






