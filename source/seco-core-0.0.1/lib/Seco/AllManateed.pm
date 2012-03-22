#SYNOPSYS
#	# Send the ls command via manateed to a list of hosts
#	#
#
#	BEGIN { unshift(@INC,"/home/seco/tools/lib") }
#
#	use AllManateed;
#	my $am = new AllManateed;
#
#	# optional parameter setting, default values are shown here
#   # If called with no arguments, the method will return the default
#   # or current setting for that value.
#
#	$am->port(12345) ;
#	$am->tcp_timeout(5);
#	$am->read_timeout(20);
#	$am->maxflight(0);  # Set to a bigger number to limit # of open tcp sessions
#       $am->randomize(0);  # Do not randomize connection order
#
#
#
#	my %result = $am->command ("i2200", "ls /tmp");
#	foreach $host ( keys %result ) {
#		foreach $line (@{$result{$host}} ) {
#			print "$host:$line";
#		}
#	}
package Seco::AllManateed;
use strict;
use Symbol;

BEGIN { unshift(@INC,"/home/tops/tools/lib") }

use Seco::FnSeco;

use vars qw($port %results $read_timeout $tcp_timeout %errors $maxflight $sleep $debug $randomize);

$maxflight = 0;
$randomize = 0;
$read_timeout = 20;
$tcp_timeout = 5;
$port = 43698;
$sleep = 0;
$debug = 0;
1;

sub new {
	my ($class, $init) = @_;
    my $self;
    if (ref $init) {
    $self = $init->clone;
    } else {
    $self = bless {
        'command'       => undef,
    }, $class;
    }

}


sub command {
  my ($self, $nodes, $command) = @_;

	my %results;
	my %nodes = ExpandRange($nodes);
	my @nodes = sort( keys %nodes);
           fisher_yates_shuffle(\@nodes)  if ($self->randomize());
        my ($maxflight) = $self->maxflight();
        my (@pending);
        my ($counter)=0;
        my ($host,$h,%socket);
        my ($port) = $self->port();
        my ($sleep) = $self->sleep();
  
        foreach $host (@nodes) {
           $socket{$host} = $self->CreateSocket($host,$port);
	   next unless ($socket{$host});

	   ### If we're doing max in flight, send the commands now
	   if($maxflight) {
           $self->SendCommandSocket($host,$socket{$host},$command);
           sleep $sleep if $sleep;
           push(@pending,$host);
           $counter++;
           if (($maxflight) && ($counter >= $maxflight)) {
		$h = shift @pending;  $counter--;
		@{$results{$h}} = $self->ReadResultsSocket($h,$socket{$h});
	   }
	   }
        }

	### If we're not doing max in flight, then we haven't send the
	### commands and need to do that now
	if( !$maxflight)
	{
	   foreach $host (@nodes)
	   {
	      next unless ($socket{$host});
#             print "pushing $host\n";
              push(@pending,$host);
              $self->SendCommandSocket($host,$socket{$host},$command);
              sleep $sleep if $sleep;
	   }
        }

        while($h = shift @pending) {
#          print "Read $h from pending\n";
          @{$results{$h}} = $self->ReadResultsSocket($h,$socket{$h});
        }
 
	return %results;
}

sub port {
	my ($self, $port_assignment) = @_;
	$self->{port} = $port_assignment if (defined $port_assignment);
	exists $self->{port} ? $self->{port} : $port;
}

sub sleep {
	my ($self, $sleep) = @_;
	$self->{sleep} = $sleep if (defined $sleep);
	exists $self->{sleep} ? $self->{sleep} : $sleep;
}

sub tcp_timeout {
	my ($self, $tcp_timeout_assignment) = @_;
	$self->{tcp_timeout} = $tcp_timeout_assignment if (defined $tcp_timeout_assignment);
	exists $self->{tcp_timeout} ? $self->{tcp_timeout} : $tcp_timeout;
}

sub read_timeout {
	my ($self, $read_timeout_assignment) = @_;
	$self->{read_timeout} = $read_timeout_assignment if (defined $read_timeout_assignment);
	exists $self->{read_timeout} ? $self->{read_timeout} : $read_timeout;
}

sub maxflight {
	my ($self, $maxflight_assignment) = @_;
	$self->{maxflight} = $maxflight_assignment if (defined $maxflight_assignment);
	exists $self->{maxflight} ? $self->{maxflight} : $maxflight;
}

sub randomize {
	my ($self, $randomize_assignment) = @_;
	$self->{randomize} = $randomize_assignment if (defined $randomize_assignment);
	exists $self->{randomize} ? $self->{randomize} : $randomize;
}


sub debug {
	my ($self, $debug_assignment) = @_;
	$self->{debug} = $debug_assignment if (defined $debug_assignment);
	exists $self->{debug} ? $self->{debug} : $debug;
}


sub CreateSocket {
	my ($self, $host, $port) = @_;

		print "Create socket for host $host\n" if ($self->debug());
		my $s = gensym() ;

		if( open_tcp_socket($s, $host, $port, $self->tcp_timeout) == 0)
			{
				#print STDERR "open_tcp_socket: ", $host, ": ", $Seco::Err, "\n";
				push( @{$self->{errors}{$host}}, $Seco::Err) ;
				return undef;
			}
		return $s;
}


sub  SendCommandSocket {
	my ($self, $host,$s, $command) = @_;
    ### Only do hosts that have valid sockets
	return if( !$s);
	select((select($s), $| = 1)[$[]);
	print $s "$command \n";
}


sub ReadResultsSocket {
	my ($self, $host,$s) = @_;
	my (@results);
	print "Read socket for host $host\n" if ($self->debug);

	unless( ReadAll( $s, $self->read_timeout))
	{
			#print STDERR "$host: WARNING: incomplete read from socket\n";
			push( @{$self->{errors}{$host}}, "WARNING: incomplete read from socket") ;
	}

	while ( $_ = ReadLine($s))
           {  chomp($_); push(@results,$_) ; }

        close($s);

	return @results;
}



sub errors {
    my ($self) = @_;
    return %{$self->{errors}} if (defined $self->{errors} );

    return();

}

# fisher_yates_shuffle( \@array ) : generate a random permutation
# of @array in place
sub fisher_yates_shuffle {
    my $array = shift;
    my $i;
    for ($i = @$array; --$i; ) {
        my $j = int rand ($i+1);
        next if $i == $j;
        @$array[$i,$j] = @$array[$j,$i];
    }
}

sub netcat {
  my($host,$port,$string,$timeout) = @_;
  my $self = new Seco::AllManateed;
  $self->port($port);
  $self->read_timeout($timeout || 60);
  my %results = $self->command($host,$string);
  if (defined $results{$host}) {
    return @{ $results{$host}  };
  } else {  
    return;
  }
}
