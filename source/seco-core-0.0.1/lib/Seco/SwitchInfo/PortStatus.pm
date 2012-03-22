package Seco::SwitchInfo::PortStatus;

use warnings;
use strict;
use ManateedClient;
use Data::Dumper;

my $mc = new ManateedClient;

# we expect a username and password
sub new {
    my ($class, %init) = @_;
    die "need user and pass: new(user => '', pass => '')"
      unless exists $init{user} and exists $init{pass};
    die "need switch hostname: new(switch => 'c2950-136.sci'"
      unless exists $init{switch};
    die "need switch type: new(swtype => 'sc5')"
      unless exists $init{swtype};
    return bless { %init }, $class;
}

sub scrape {
    my ($self) = @_;
    return $self->scrape_sc5 if $self->{swtype} =~ /sc/; # sci
    return $self->scrape_re1 if $self->{swtype} =~ /re1/;
}

# return port numbers that we were able to scrape
sub ports {
    my ($self) = @_;
    return keys %{$self->{scrape}}
}

sub duplex {
    my ($self, $port) = @_;
    return $self->{scrape}->{$port}->{duplex};
}

sub vlan {
    my ($self, $port) = @_;
    return $self->{scrape}->{$port}->{vlan};
}

sub speed {
    my ($self, $port) = @_;
    return $self->{scrape}->{$port}->{speed};
}

sub type {
    my ($self, $port) = @_;
    return $self->{scrape}->{$port}->{type};
}

sub scrape_sc5 {
    my ($self) = @_;
    $mc->command($self->{user}."\n".$self->{pass}.
                 "\nterminal length 0\nshow interface status\n\nexit\n");
    $mc->nodes($self->{switch});
    $mc->timeout(25);
    $mc->port(23);
    my $out = $mc->run->{$self->{switch}}->{output};
    my $r;
    while ($out =~ m!^(\w+\d+)/(\d+) \s+ connected \s+
           (\d+) \s+ (\S+) \s+ (\S+) \s+
           (\S+TX) \s*$!xsmg) {
        $r->{$2} = {
                    ifname => $1,
                    vlan => $3,
                    duplex => $4,
                    speed => $5,
                    type => $6,
                   }
    }
    $self->{scrape} = $r;
    return $r;
}


sub scrape_re1 {
    die "implement me";
    my ($self) = @_;
    $mc->command($self->{user}."\n".$self->{pass}.
                 "\nterminal length 0\nshow interface brief\n\nexit\n");
    $mc->nodes($self->{switch});
    $mc->timeout(25);
    $mc->port(23);
    my $out = $mc->run->{$self->{switch}}->{output};
    my $r;
    # This regex needs to be modified to match the output for these switches
    while ($out =~ m!^(\w+\d+)/(\d+) \s+ connected \s+
           (\d+) \s+ (\S+) \s+ (\S+) \s+
           (\S+TX) \s*$!xsmg) {
        $r->{$2} = {
                    ifname => $1,
                    vlan => $3,
                    duplex => $4,
                    speed => $5,
                    type => $6,
                   }
    }
    $self->{scrape} = $r;
    return $r;
}

our %switches = (
                 SCI => {
                         command => "show interface status",
                         regex   => qr!^(\w+\d+/\d+) # port
                                         \s+
                                         connected # status
                                         \s+
                                         (\d+) # vlan
                                         \s+
                                         (\S+) # duplex
                                         \s+
                                         (\S+) #speed
                                         \s+
                                         (\S+TX) # type
                                         \s*$!x,
                        },
                         # RE1 not working
                 RE1 => {
                         command => "show interface brief",
                         regex   => qr!^ \s+
                                         (\w+\d+/\d+) # port
                                         \s+
                                         100/1000T # type
                                         \s+ \| \s+
                                         (Yes|No) # Intrusion Alert
                                         \s+
                                         (Yes|No) # Enabled
                                         (\w+)    # Status
#################################
                                         \s*$!x,
                        },
                );


1;

__END__

=pod

=head1 NAME

  Seco::SwitchInfo::PortStatus - Scrape a switch for the status of its ports

=head1 SYNOPSIS

  use Seco::SwitchInfo::PortStatus;
  my $sw = new Seco::SwitchInfo::PortStatus ( user => 'eam',
                                              pass => 'changeme',
                                              switch => 'c2950-136.sci',
                                              swtype => 'sc5',
					    );
  $sw->scrape;

  foreach my $port ($sw->ports) {
    print "Duplex on port $port is " . $sw->duplex($port);
  }

=head1 DESCRIPTION

B<Seco::SwitchInfo::PortStatus> logs into a switch via telnet and figures out
various port states.

=head1 METHODS

=over 4

=item new(TYPE)

C<new> create new Seco::SwitchInfo::PortStatus object

=item scrape()

C<scrape> invokes a scrape of the switch, populating the object with the current
state of the switch.

=item ports()

C<ports> returns a list of ports that the switch told us about.

=item duplex(PORT)

C<duplex> returns the duplex status of a given port.

=item vlan(PORT)

C<vlan> returns the vlan status of a given port.

=item speed(PORT)

C<speed> returns the speed status of a given port.

=item type(PORT)

C<type> returns the type status of a given port.

=back

=head1 EXAMPLES

=head2 see SYNOPSYS

=head1 AUTHOR

  Evan Miller <eam@yahoo-inc.com>

=cut



