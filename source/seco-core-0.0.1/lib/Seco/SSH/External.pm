package Seco::SSH::External;

=pod

=head1 NAME

Seco::SSH::External - Run commands via SSH

=head1 SYNOPSIS

  use Seco::SSH::External;

  my $ssh = Seco::SSH::External->new(-cmd => "pwd", -timeout => 5);
  my $result = $ssh->run("pain.inktomisearch.com");
  if $result->ok print "Success! Output was: ", $result->stdout;

=head1 DESCRIPTION

B<Seco::SSH::External> provides a simple interface for running commands
via ssh with timeouts and error handling.

=head1 METHODS

=cut


use warnings;
use strict;
use Net::SSH;
use Seco::SSH::External::Result;
use Data::Dumper;
use IO::Select;
use IO::Handle;
use POSIX qw( :sys_wait_h );

use constant TIMEOUT => 30;	# Default wait 30 seconds for commands to finish
use constant BUFFSZ  => 4096; # how much to read per sys(read|write)

@Net::SSH::ssh_options = qw( -T -o BatchMode=yes ); # Without setting these
                                                    # Net::SSH sucks.

=item new()

 Make a new Seco::SSH::External object. Useful for setting defaults
 in the case of repeated command execution. Options to the run() method
 will override instance defaults.

=cut

sub new {
    my ($class, @init) = @_;
    if (ref $init[0] eq 'HASH') {
        return my $self = bless $init[0], $class;
    } else {
        return my $self = bless { @init }, $class;
    }
}

=item run()

 Run the ssh session. Mandantory arguments are a minimum of $host
 and $cmd, though if invoked from an Seco::SSH::External instance
 any defaults will be used.

=cut

sub run {
    my ($self, $host, $cmd, $timeout, $input) = @_;
    if (ref $host eq 'HASH') {
        my $t = $host;
        $host = $t->{-host} if exists $t->{-host};
        $cmd = $t->{-cmd} if exists $t->{-cmd};
        $input = $t->{-input} if exists $t->{-input};
        $timeout = $t->{-timeout} if exists $t->{-timeout};
    }
    if (ref $self eq 'HASH') {
        $timeout ||= $self->{-timeout} || TIMEOUT;
        $host ||= $self->{-host};
        $cmd ||= $self->{-cmd};
        $input ||= $self->{-input};
    }
    $timeout ||= TIMEOUT;
    my ($in, $out, $err) = map {new IO::Handle} 1..3;
    my %r = ( -stdout => '', -stderr => '');
    $r{-pid} = Net::SSH::sshopen3($host, $in, $out, $err, $cmd);
    #sleep 2;
    my $select_in = IO::Select->new($in);
    my $select_out = IO::Select->new($out, $err);
    unless (defined $input) {
        $select_in->remove($in);
        close $in;
    }
    my $start = time;
    my $windex = 0;
    my $rindex = 0;
  OUTER:
    while ($select_in->count or $select_out->count) {
        #my ($rfh, $wfh, $efh) = $select->select(undef, undef, 0.25);
        my ($rfh, $wfh, $efh) = IO::Select->select($select_out,$select_in, undef, 0.25);
        next unless 3 == grep { ref $_ eq 'ARRAY' } ($rfh, $wfh, $efh);
        if (@$wfh) {
            if (!$in->opened) {
                $select_in->remove($in);
                $r{-wexception} = "Broken pipe";
            } else {
                my $bytes = syswrite($in, $input, BUFFSZ, $windex);
                if (!defined $bytes) {
                    $r{-wexception} = $!;
                    last OUTER; # Maybe we don't want to fail out FIXME
                }
                $windex += $bytes;
                if (length $input == $windex) {
                    $select_in->remove($in);
                    close($in);
                }
            }
        }
        foreach my $fh (@$rfh) {
            my $buff = '';
            my $bytes = sysread($fh, $buff, BUFFSZ);
            if (!defined $bytes) {
                $r{-exception} = $!;
                last OUTER;
            }
            $select_out->remove($fh) unless $bytes; # EOF reached
            if ($fh eq $out) {
                $r{-stdout} .= $buff;
            } elsif ($fh eq $err) {
                $r{-stderr} .= $buff;
            }
        }
    } continue {
        if ($start + $timeout < time) {
            $r{-timedout} = 888; # let's not wait
            last OUTER;        # around all damn day
        }
    }
    $r{-retval} = $? if waitpid($r{-pid}, POSIX::WNOHANG);
    while ((not defined $r{-retval}) and ($start + $timeout > time)) {
        print "$start + $timeout and ", $_=time, "\n";
        IO::Select->select((undef)x3, 0.25);
        $r{-retval} = $? if waitpid($r{-pid}, POSIX::WNOHANG);
    }
    # At this point, if we don't have retval it's a runaway process.
    if (not defined $r{-retval}) {
        $r{-timedout} = 1;
        $r{-kill9} = 1;
        kill 9, $r{-pid};
        IO::Select->select((undef)x3, 0.25);
        $r{-retval} = $? if waitpid($r{-pid}, POSIX::WNOHANG); # last ditch
    }
    $r{-time} = time - $start;
    return new Seco::SSH::External::Result \%r;
}


1;

__END__


=head1 EXAMPLES

=head2 loop running uptime on a host

  my $ssh = Seco::SSH::External->new( -cmd => "uptime",
                                      -timeout => 5,
                                      -host => "pain"
                                    );
  print $ssh->run->stdout while sleep 1;

=head2 Checking return value

  my $result = Seco::SSH::External->run("pain", "ls /tmp", 10);
  die "Had major error" unless $result->ok;
  die "Had minor error: " . $result->stderr unless $result->strictok;

=head2 Feed some input to the ssh process

  my $result = Seco::SSH::External->run("pain",
                                        "sed s/foo/bar/g",
                                        10,
                                        "foo foo foo, foo foobra-ann"
                                       );
  if ($result->ok) {
      print $result->stdout;
  } else {
      die "oh crap!"
  }

=head1 AUTHOR

  Evan Miller <eam@yahoo-inc.com>

=cut
