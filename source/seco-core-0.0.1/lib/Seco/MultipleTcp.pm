package Seco::MultipleTcp::Node;
use base qw(Class::Accessor);
Seco::MultipleTcp::Node->mk_accessors( qw/
                                          started bytes_written name
                                          readbuf ended cleanly
                                          error read_error write_error
                                          / );

use overload
  '""' => sub { shift->stringify_self };


sub new {
    my ($class, $node) = @_;
    my $self = bless {
                      started => time,
                      bytes_written => 0,
                      readbuf => "",
                      writebuf => "",
                      name => $node,
                     }, $class;
    return $self;
}

sub stringify_self {
    my ($self) = @_;
    my $s = $self->name . ": bytes_written " . $self->bytes_written .
      " bytes, read " . (length $self->readbuf) . " bytes. " .
        ($self->ok ? "Was ok" : ($self->error or
                                 $self->write_error or
                                 $self->read_error or
                                 "huh")). "." ;
    if ($self->started and $self->ended) {
        $s .= " Total time in flight: " . ($self->ended - $self->started) .
          " seconds.";
    }
    return $s;
}

sub ok {
    my ($self) = @_;
    return 0 if $self->write_error;
    return 0 if $self->read_error;
    return 0 if $self->error;
    return 0 unless $self->cleanly;
    return 1; # FIXME additional checks
}

sub not_ok {
    my ($self) = @_;
    return ! $self->ok;
}

package Seco::MultipleTcp::Result;
use base qw(Class::Accessor);

# filter the result for a list of nodes
sub nodes {
    my ($self) = @_;
    if (wantarray) {
        return keys %$self;
    } else {
        return scalar keys %$self;
    }
}
sub ok {
    my ($self) = @_;
    return grep { $_->ok } values %$self if wantarray;
    return scalar grep { $_->ok } values %$self;
}

sub not_ok {
    my ($self) = @_;
    return grep { !$_->ok } values %$self if wantarray;
    return scalar grep { !$_->ok } values %$self;
}

sub all {
    my ($self) = @_;
    if (wantarray) {
        return values %$self;
    } else {
        return scalar values %$self;
    }
}

package Seco::MultipleTcp;
use base qw(Class::Accessor);
Seco::MultipleTcp->mk_accessors( qw/
                                    maxflight writebuf
                                    global_timeout sock_timeout
                                    debug port select_period
                                    global_start nodewritebuf
                                    minimum_time 
                                    shuffle reverse_radix
                                    yield_sock_finish
                                    yield_sock_timeout
                                    yield_sock_start
                                    yield_after_select
                                    / );

use warnings;
use strict;
use Socket;
use IO::Select;
use Fcntl;
use List::Util;

use constant TCP_PROTO => scalar getprotobyname("tcp");


our %defaults = (
                 maxflight => 500,
                 writebuf => "",
                 global_timeout => 0, # max time for entire run
                 sock_timeout => 60, # max time to wait on an individual socket
                 debug => 0,
                 shuffle => 0,
                 minimum_time => 0,          # delay between reuse of a socket slot
                 port => 12345,
                 select_period => 1, # Don't change this, internal select period
                 nodewritebuf => { },
                );


sub new {
    my ($class, %init) = @_;
    my $self = bless { (%defaults, %init) }, $class;
    $self->{result} = Seco::MultipleTcp::Result->new;
    return $self;
}

sub time_left {
    my ($self, $time) = @_;
    return 1 unless $self->{global_timeout};
    return ($time < $self->{global_start} + $self->{global_timeout});
}

sub run {
    my ($self, @nodes) = @_;
    @nodes = @{$nodes[0]} if @nodes and ref $nodes[0] eq 'ARRAY';
    @nodes = $self->nodes unless @nodes;
    @nodes = List::Util::shuffle @nodes if $self->shuffle;
    @nodes = _reverse_radix(@nodes) if $self->reverse_radix;
    
    $self->{read_select} = new IO::Select;
    $self->{write_select} = new IO::Select;
    
    $self->{global_start} = time;
    $self->{global_stop} = $self->{global_start} + $self->{global_timeout};
    
    while ( $self->time_left(my $time = time) and
            (@nodes or values %{$self->{h2s}}) ) {
            warn "current in flight: ".$self->current_in_flight.
                 " and maxflight ".$self->maxflight if $self->debug;
        while (($self->current_in_flight < $self->maxflight) and @nodes) {
            my $node = shift @nodes;
            $self->add_new_node($node);
            $self->yield("sock_start", $self->yield_sock_start, $node)
              if $self->yield_sock_start;
        }
        
        my @selected = IO::Select->select($self->{read_select},
                                          $self->{write_select}, undef,
                                          $self->select_period);
        $self->yield("after_select", $self->yield_after_select, @selected)
          if $self->yield_after_select;
        if (@selected) {
            my ($read, $write, $error) = @selected;
            
            # handle write logic, remove from write_select if complete/error
            for my $s (@$write) {
                my $bytes;
                my $hostname = $self->{s2h}{$s};
                my $str = ($self->{nodewritebuf}{$hostname} or
                           $self->{writebuf});
                eval {
                    $bytes = syswrite($s,
                                      $str,
                                      length $str,
                                      $self->{result}{ $self->{s2h}{$s} }{bytes_written} );
                };
                if ($@) {
                    $self->{result}{ $self->{s2h}{$s} }{write_error} = $@;
                    $self->{write_select}->remove($s);
                } elsif (defined $bytes) {
                    $self->{result}{ $self->{s2h}{$s} }{bytes_written} +=
                      $bytes;
                } else {
                    $self->{result}{ $self->{s2h}{$s} }{write_error} = $!;
                    $self->{write_select}->remove($s);
                }
                $self->{write_select}->remove($s)
                  if $self->{result}{ $self->{s2h}{$s} }{bytes_written} ==
                    length $str;
            }
            
            # handle read logic, remove from read_select if complete/error
            # reads MUST go after writes to prevent EPIPE
            for my $s (@$read) {
                my $bytes = sysread($s, my $buf, 4096);
                if (! defined $bytes) {
                    $self->{result}{ $self->{s2h}{$s} }{read_error} = $!;
                    $self->{read_select}->remove($s);
                } elsif ($bytes == 0) {
                    $self->{read_select}->remove($s);
                } else {
                    $self->{result}{ $self->{s2h}{$s} }{readbuf} .= $buf;
                }
            }
            
        } else {
            warn "IO::Select returned no handles, likely timeout"
              if $self->debug;
        }
        
        for my $sock (values %{$self->{h2s}}) {
            # don't remove unless we've gone minimum runtime
            my $node = $self->{s2h}{$sock};
            next if $self->{result}{$node}{started} + $self->minimum_time > $time;
            if (!$self->{read_select}->exists($sock) and
                !$self->{write_select}->exists($sock)) {
                warn "deleting $sock due to no read/write selects left"
                  if $self->debug;
                # socket is done reading and writing, clean it up
                delete $self->{s2h}{$sock};
                delete $self->{h2s}{$node};
                close $sock;
                $self->{result}{$node}{ended} = $time;
                $self->{result}{$node}{cleanly} = 1;
                $self->yield("sock finish", $self->yield_sock_finish, $node)
                  if $self->yield_sock_finish;
                next;
            }

            # sock_timeout of 0 never times out
            if ($time > $self->{result}{ $self->{s2h}{$sock} }{started} +
                $self->sock_timeout and $self->sock_timeout) {
                warn "deleting $sock due to socket level timeout"
                  if $self->debug;
                $self->{read_select}->remove($sock)
                  if $self->{read_select}->exists($sock);
                $self->{write_select}->remove($sock)
                  if $self->{write_select}->exists($sock);
                delete $self->{s2h}{$sock};
                delete $self->{h2s}{$node};
                close $sock;
                $self->{result}{$node}{ended} = $time;
                $self->{result}{$node}{error} = "timed out";
                $self->yield("sock timeout", $self->yield_sock_timeout, $node)
                  if $self->yield_sock_timeout;
                next;
            }
        }
    }
    
    # all done, return data
    # in prod, return tcp return object
    return $self->{result};
}

sub current_in_flight {
    my ($self) = @_;
    return 0 unless exists $self->{s2h} and ref $self->{s2h} eq 'HASH';
    return scalar keys %{$self->{s2h}};
}

sub add_new_node {
    my ($self, $node) = @_;
    warn "adding $node" if $self->debug;
    my $sock;
    my $port = $self->port;
    my $hostname = $node;
    if ($node =~ /(.*):(\d+)$/) {
        $hostname = $1;
        $port = $2;
    }
    eval {
        my $ip = gethostbyname($hostname)
          or die "bad hostname\n"; # FIXME allow ip
        my $sa_in = sockaddr_in($port, $ip);
        socket($sock, PF_INET, SOCK_STREAM, TCP_PROTO)
          or die "socket error: $!\n";
        _set_nonblock($sock);
        connect($sock, sockaddr_in($port, $ip));
        die "generally bad sock\n" unless $sock;
    };
    if ($@) {
        warn "raised: $@" if $self->debug;
        $self->{result}{$node} = new Seco::MultipleTcp::Node $node;
        chomp $@;
        $self->{result}{$node}{error} = $@;
        return;
    }
    $self->{read_select}->add($sock);
    $self->{write_select}->add($sock);
    $self->{result}{$node} = new Seco::MultipleTcp::Node $node;
    
    # do I need both of these?
    # when both select objects are done, close and remove the socks.
    warn "sock node $sock $node" if $self->debug;
    $self->{s2h}{$sock} = $node;
    $self->{h2s}{$node} = $sock;
}

sub nodes {
    my ($self, @arg) = @_;
    $self->{nodes} = $arg[0] if @arg and ref $arg[0] eq 'ARRAY';
    $self->{nodes} = \@arg if @arg and ref $arg[0] ne 'ARRAY';
    return wantarray ? @{$self->{nodes}} : length @{$self->{nodes}};
}

sub yield {
	my ($self, $id, $code, @args) = @_;
	warn "in yield id '$id' with $code and args '@args'" if $self->debug;
	$code->($self, @args);
}

sub _set_nonblock {
    my ($sock) = @_;
    my $flags = fcntl($sock, F_GETFL, 0);
    my $newflags = ($flags | O_NONBLOCK);
    fcntl($sock, F_SETFL, $newflags) unless $flags == $newflags;
}

# FIXME currently not a full radix sort, just sort on last character
sub _reverse_radix {
    map { $_->[0] }
    sort { $a->[1] cmp $b->[1] }
    map { [ $_, substr($_,-1,1) ] } @_;
}

1;

__END__

=pod

=head1 NAME

  Seco::MultipleTcp - generic library for fast, parallel tcp sessions

=head1 USAGE

  use Seco::MultipleTcp;
  my $m = new Seco::MultipleTcp;
  $m->nodes(qw/ pain blazes ks321000 /); # array or arrayref
  $m->port(12345);
  $m->sock_timeout(60);                  # wait 60 seconds max per connection
  $m->global_timeout(300);               # no more than 5 minutes for the full operation
  $m->minimum_time(5);                   # wait at least 5 seconds on each connection
  $m->writebuf("nodeinfo\n");            # write this out
  $m->maxflight(50);                     # maximum parallel

  my $res = $m->run;

  print "There are ". $res->nodes ." total nodes";
  print "There are ". $res->ok ." ok nodes, as follows:";
  for my $node ($res->ok) {
    print "$node";
  }

  print "There are ". $res->not_ok ." NOT ok nodes, as follows:";
  for my $node ($res->not_ok) {
    print "$node";
  }

  print "Iterating all nodes:";
  for my $node ($res->nodes) {
  	print "This Node object for host " . $node->name . " read this data: " . $node->readbuf;
  }

=head1 DESCRIPTION


Create a Seco::MultipleTcp object, set parameters and execute a pass of connections. The run()
method will return a hash blessed as a Seco::MultipleTcp::Result object. A Seco::MultipleTcp::Result
is made up of Seco::MultipleTcp::Node objects.

It's mostly backwards compatible with AllManateed and ManateedClient. The blessing on the returned
hash can be ignored, and the returned values treated as a regular hash of hashes.

