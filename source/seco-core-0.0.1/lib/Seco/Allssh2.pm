#
# Allssh.pm - Phillip Moore <pdm@inktomi.com)   May 8, 2000
# $Id: //depot/manatee/main/tools/lib/Allssh.pm#37 $ 
# For docs: perldoc Allssh
#

package Seco::Allssh2;

use strict;
use Symbol;
use Net::Ping;
use POSIX ":sys_wait_h";
use Data::Dumper;



BEGIN { unshift(@INC,"/home/tops/tools/lib") }
use Seco::FnSeco;



use vars qw($sshport $timeout $pingfirst $sshbin $binary %pids %srcs $logdir $logkey @outfiles %exitcodes $cleanup @downhosts $verbose $format $maxflight $pause $setuid $maxtime $nodes2 $sourceonce);

 my $tmpdir = exists $ENV{TMPDIR} ? $ENV{TMPDIR} : "/tmp";
    $tmpdir = "/tmp" unless (-d $tmpdir);

$setuid = undef;
$sshport = 22;
$timeout = 0;
$pingfirst = 1;
$cleanup = 1; 
$verbose = 0; 
$format = 0;
$sshbin = "/usr/bin/ssh";
$logdir = "/${tmpdir}/";
$logkey = "allssh";
$maxflight = 0; # unlimited 
$pause = 0; # unlimited 
$binary = 0; # Don't use binary spawn
$sourceonce = 0; # If multiphasic, don't reuse the first source
$maxtime = 0; # Don't set alarms for the children
$nodes2 = ""; # No other nodes by default

unless (-x $sshbin)  {
  my $paths = "/usr/sbin:/sbin:/usr/bin:/bin:/usr/local/sbin:/usr/local/bin:" . $ENV{"PATH"};
  ($sshbin) = grep(-x "$_/ssh",split(/:/,$paths));
  die "Could not find 'ssh' in $paths" unless (defined $sshbin);
  $sshbin .= "/ssh";
  #  print "sshbin is at $sshbin, found with paths=$paths\n";
}


sub new {
    my ($class, $init) = @_;
    my $self;
    $self->{sources} = [];
    if (ref $init) {
    $self = $init->clone;
    } else {
    $self = bless {
        'command'       => undef,
        'print_output'       => undef,
    }, $class;
    }

}




sub command {

	my ($self, $nodes, $command, @sshargs) = @_;

	my %nodes = ExpandRange($nodes);
	my @nodes = sort( keys %nodes);

	my %nodes2 = ExpandRange($self->nodes2());
	my @nodes2 = sort { $a <=> $b } ( keys %nodes2);


	my ($host, $pid, $node2);


	my ($counter) = 0;
        my (@remaining) = @nodes;
        my ($verbose) = $self->verbose();
	my ($format) = $self->format();
	my $nohang = ($self->maxtime()) ? &WNOHANG : 0;
        my $i;

        my (@ping,$ping);
	%{$self->{killat}} = ();

         sub adjustme {
          my($host,$offset,$keepprefix,$format) = @_;
          my($width,$new_number,$formatted);
          $host =~ m/(\D+)(\d+)(\D*)/;
          my ($prefix,$number,$suffix) = ($1,$2,$3);
          if (!$keepprefix) {$prefix="";};
          $width=length($number);
          $new_number=int(eval("$number$offset"));
	  if ($format) {
            $formatted=sprintf($format,$new_number);
	  } else {
            $formatted=sprintf('%0'.$width.'i',$new_number);
	  }
          #print "input: $host prefix=$prefix width=$width nn=$new_number formated=$formatted suffix=$suffix ${prefix}${formatted}${suffix}\n";
          return "${prefix}${formatted}${suffix}";
         }

         sub adjusti {
	  my ($i,$format) = @_;
	  if ($format) { $i = sprintf($format,$i); }
	  return $i;
         }


        my %alive; my @alive;
        $ping = $self->pingfirst;
        if ($ping =~ m/icmp/i) {
            @ping = ("icmp");
            if (( $^O =~ m/linux/) && 
        (scalar grep(-x "$_/fping", split(/:/,  $ENV{"PATH"}) ) ) 
              ) { 
              print STDERR "INFO: fping found, running against node list\n" if ($verbose);
              @alive = `/home/tops/candy/bin/standardNodesParser -e -r $nodes | fping -a 2>/dev/null`;
              foreach (@alive) {
                  chomp;
                  $alive{$_}++;
              }
              print STDERR "INFO: number of nodes alive: " . (scalar @alive) . "\n" if ($verbose);
              unless (scalar @alive) {
		print STDERR "WARNING: we tried fping, but got back no positive response (or fping was unavailable).  Will resort to Net::Ping\n";
              }
            }
        } elsif ($ping =~ m/^0?$/) { 
            undef @ping;
        } elsif ($ping =~ m/^(tcp|1)$/i) {
            @ping = ("tcp",22);
        } else {
            @ping = ("tcp",$ping);
        }

                  
        while($host = shift @nodes) {
		# Iterate over the second range if available.
		if ($#nodes2 > -1) {
			$node2 = shift @nodes2;
			push(@nodes2,$node2);
		}
		my $source;
                if ( scalar %alive) {
			print STDERR "INFO: Ping $host @ping \n" if ($verbose >= 1);
			if (! defined $alive{$host}) {
				warn "ERROR: $host is down (per fping), skipping\n" if ($verbose) ;
				push (@{$self->{downhosts}}, $host);
				next;
			}
                }
		elsif ( @ping ) {
			print STDERR "INFO: Ping $host @ping \n" if ($verbose >= 1);
			my $ping = new Net::Ping(@ping) ;	
			if (! $ping->ping($host, 5) ) {
				warn "ERROR: $host is down, skipping\n" if ($verbose) ;
				push (@{$self->{downhosts}}, $host);
				next;
			}

			$ping->close();
		}
	
		my $outfile = "$logdir/$host.$logkey.$$";
		my $newcommand = $command;

                # Escape a later of { } 
		$newcommand =~ s/{{([a-z+-]*)}}/\xff\xff$1\xff\xff/g;
              
                # Convert {} to the target host
		$newcommand =~ s/{}/$host/g;

		# Convert {R/r} to secondary range node
		$newcommand =~ s/{[Rr]}/$node2/g;
 
                # Convert {q}=", {sq}=', {bq}=`
		$newcommand =~ s/{q}/"/g;
		$newcommand =~ s/{sq}/'/g;
		$newcommand =~ s/{bq}/\`/g;

                # Make {me+100} turn into the hostname offset by +100
                # Make {mme+100} turn into the hostname's *number*, offset by +100 (no prefix/suffix)
                $newcommand =~ s/{me([-+]\d+)}/adjustme($host,$1,1,$format)/ge;
                $newcommand =~ s/{mme([-+]\d+)}/adjustme($host,$1,0,$format)/ge;
                $newcommand =~ s/{mei([-+]\d+)}/adjustme($host,$1,0,$format)/ge;
		$i++;	# increment this once, not per replacement
		$newcommand =~ s/{i}/adjusti($i,$format)/ge;
		$newcommand =~ s/{sleeprand\((\d+)\)}/sleeprand($1)/ge;

 		sub sleeprand {
  			my $r = rand($_[0]);
			sleep $r;
			return "";
		}

		# Perform binary spawning replacement
		if ($self->binary()) {
			$source = $self->source();
			$newcommand =~ s/{rsync}/$source/;
		}

                # Unescape a layer of { }
                $newcommand =~ s/\xff\xff([a-z]*)\xff\xff/{$1}/g;    

                print STDERR "$host " if ($verbose >= 1);
		
		$pid = $self->Spawn( $newcommand, $host, $outfile, @sshargs);
		$pids{$pid} = $host;
                if ($self->binary()) { $srcs{$pid} = $source; }
		push(@{$self->{outfiles}}, [$host, $outfile]);
		if ($self->maxtime()) {   
	                ${$self->{killat}}{$pid} = time + $self->maxtime();
		}
		
                $counter++;
                while ( (($self->maxflight()) && ($counter >= $self->maxflight())) || (($self->numsources() == 0) && ($self->binary())) ) {
			$pid = waitpid(-1,$nohang);
			if ($pid == 0) {
				sleep 1;
				$self->checkkillat;
				next;
			} elsif ($pid > 0) { 
				print STDERR "INFO: $pids{$pid} completed\n" if ($verbose);
				my $code = $? >> 8;
				$self->{exitcodes}{$pids{$pid}} = $code;
				print STDERR "ERROR: $pids{$pid} completed with error code $code\n" if ($code);

				if ($self->binary()) {
					# Push my source back onto the list
					if (! $self->sourceonce()) {
					  $self->source($srcs{$pid});
					}
					$self->sourceonce(0);

					# And then if I completed successfully,
					# I can be a source as well
					my $newsrc = $pids{$pid} . $self->rsync();
					$self->source($newsrc) if (! $code);

                                	delete $srcs{$pid};
				}

                                delete $pids{$pid};
				$counter--;
                        } else {
				print "Sleeping in the loop cause there were no children\n";
			    sleep(1);
                        }
                }
		sleep $self->pause() ;

	}	# end of while host loop
        print STDERR "Waiting\n" if ($verbose);
        &showwaiting if ($verbose);
	while( ($pid = waitpid(-1,$nohang)) != -1)
	{
		if (! $pid) {
                        $self->checkkillat;
			sleep 1;
			next;
		}
		print STDERR "INFO: $pids{$pid} completed\n" if ($verbose);
		my $code = $? >> 8;

		$self->{exitcodes}{$pids{$pid}} = $code;
		print STDERR "ERROR: $pids{$pid} completed with error code $code\n" if ($code);
                delete $pids{$pid};
		$counter--;
        	&showwaiting if ($verbose);
	}

} #end of command()



sub showwaiting {
        if (%pids) {
                print "Waiting for: ";
                print &CompressRange(reverse %pids);
                print "\n";
        }
}


sub outfiles {
	my ($self) = @_;
	
	return $self->{outfiles};
}

sub print_output {
	my ($self) = @_;

	my $array;
	my $line;

	foreach $array (@{$self->outfiles()} )
	{
	my ($host, $file) = @{$array} ;
    if( !( open( FILE, "$file")))
    {
        warn "ERROR: could not open file $file\n" if ($self->verbose());
    } else {
        while( defined( $line = <FILE>))
        {
            print "$host: $line";
        }
        close( FILE);
   	}

	}

}

sub return_output {
	my ($self) = @_;

	my $array;
	my $output;
	my %results;
	my $line;

	foreach $array (@{$self->outfiles()})
	{
		my ($host, $file) = @{$array} ;
		if( !( open( FILE, "$file")))
    		{
        		warn "ERROR: could not open file $file\n" if ($self->verbose());
    		} else {
			while( defined( $line = <FILE>))
        		{
				chomp $line;
            			push (@{$results{$host}}, $line);
        		}	
			
			}
		close (FILE);
	}
	return %results;

	
}

sub DESTROY {
	my ($self) = @_;

    my $array;
    my $line;

	if ($self->cleanup() ) {
    	foreach $array (@{$self->outfiles()})
    	{
    		my ($host, $file) = @{$array} ;
			unlink $file;
    	}
	}


}

sub Spawn
{
    my($self, $cmd, $machine, $outfile, @sshargs) = @_;
    my($i, $tmpstr, $pid, $host, $code);


    #chomp( $host = `hostname`);  # Why is this here?

    ### Fork off a new process
    $pid = fork;
    die "ERROR: can't fork process: error $!\n" unless (defined($pid));

    if ($pid) {
        ### original process comes here
        # Return expected process
        return $pid;
    } else {
        ### Child Process


        ### Possibly, setuid.
        my $setuid = $self->setuid();
        if ($setuid) { 
         $> = $setuid ;
         $< = $setuid ;
        }
          
        open(STDOUT, ">$outfile") || die "Can't redirect stdout to \"$outfile\" : error $!";
		open(STDERR, ">&STDOUT") || die "Can't redirect stderr to \"$outfile\" : error $!";

        ### OK, let's do it
        exec( $self->sshbin() ,  "-o", "batchmode yes", "-n", "-q", "-x", @sshargs, $machine, $cmd);
    }
    ### This code is actually never reached
    return $pid;
}




sub checkkillat {
 my($self) = @_;
 my $now = time;
 foreach my $pid (keys %{  $self->{killat} } ) {
    my $when = ${$self->{killat}}{$pid};
    if (! -d "/proc/$pid") {
	delete ${$self->{killat}}{$pid};
	next;	
    }
    if ($now > $when + 5) {
      print STDERR "KILL: Sending a kill -9 $pid  to ssh talking to host $pids{$pid}\n";
      kill(9, $pid);
    } elsif ($now > $when) {
      print STDERR "KILL: Sending a kill $pid  to ssh talking to host $pids{$pid}\n";
      kill(15, $pid);
    }
 }
}


sub pingfirst {
    my ($self, $value) = @_;
    $self->{pingfirst} = $value if (defined $value);
    exists $self->{pingfirst} ? $self->{pingfirst} : $pingfirst;
}

sub maxflight {
    my ($self, $value) = @_;
    $self->{maxflight} = $value if (defined $value);
    exists $self->{maxflight} ? $self->{maxflight} : $maxflight;
}

sub maxtime {
    my ($self, $value) = @_;
    $self->{maxtime} = $value if (defined $value);
    exists $self->{maxtime} ? $self->{maxtime} : $maxtime;
}

sub nodes2 {
    my ($self, $value) = @_;
    $self->{nodes2} = $value if (defined $value);
    exists $self->{nodes2} ? $self->{nodes2} : $nodes2;
}

sub binary {
    my ($self, $value) = @_;
    $self->{binary} = $value if (defined $value);
    exists $self->{binary} ? $self->{binary} : $binary;
}

sub sourceonce {
    my ($self, $value) = @_;
    $self->{sourceonce} = $value if (defined $value);
    exists $self->{sourceonce} ? $self->{sourceonce} : $sourceonce;
}



sub source {
    my ($self, $value) = @_;
    my ($pop);
    if (defined $value) {
	$self->binary(1);
	push(@{$self->{sources}}, $value);
	#print "Pushing $value onto list (@{$self->{sources}})\n";
	print "INFO: Multiphasic: Adding $value to the pool.\n" if ($self->verbose());
    } else {
	# No args, pop a value off and return it, else return ""
	($pop = pop(@{$self->{sources}})) ? $pop : "";
    }
}

sub numsources {
    my ($self) = @_;
    if (defined @{$self->{sources}}) {
	return scalar(@{$self->{sources}})
    } else {
	return -1;
    }
}

sub rsync {
    my ($self, $value) = @_;
    $self->{rsync} = $value if (defined $value);
    exists $self->{rsync} ? $self->{rsync} : "";
}

sub pause {
    my ($self, $value) = @_;
    $self->{pause} = $value if (defined $value);
    exists $self->{pause} ? $self->{pause} : $pause;
}

sub cleanup {
    my ($self, $value) = @_;
    $self->{cleanup} = $value if (defined $value);
    exists $self->{cleanup} ? $self->{cleanup} : $cleanup;
}
sub verbose {
    my ($self, $value) = @_;
    $self->{verbose} = $value if (defined $value);
    exists $self->{verbose} ? $self->{verbose} : $verbose;
}
sub format {
    my ($self, $value) = @_;
    $self->{format} = $value if (defined $value);
    exists $self->{format} ? $self->{format} : $format;
}
sub timeout {
    my ($self, $value) = @_;
    $self->{timeout} = $value if (defined $value);
    exists $self->{timeout} ? $self->{timeout} : $timeout;
}
sub sshport {
    my ($self, $value) = @_;
    $self->{sshport} = $value if (defined $value);
    exists $self->{sshport} ? $self->{sshport} : $sshport;
}
sub sshbin {
    my ($self, $value) = @_;
    $self->{sshbin} = $value if (defined $value);
    exists $self->{sshbin} ? $self->{sshbin} : $sshbin;
}
sub logkey {
    my ($self, $value) = @_;
    $self->{logkey} = $value if (defined $value);
    exists $self->{logkey} ? $self->{logkey} : $logkey;
}
sub logdir {
    my ($self, $value) = @_;
    $self->{logdir} = $value if (defined $value);
    exists $self->{logdir} ? $self->{logdir} : $logdir;
}

sub downhosts {
    my ($self, $value) = @_;
    return $self->{downhosts} if (defined $self->{downhosts} );
}

sub exitcodes {
    my ($self, $value) = @_;
    return %{$self->{exitcodes}} if (defined $self->{exitcodes} );
}

sub setuid {
    my ($self, $value) = @_;
    $self->{setuid} = $value if (defined $value);
    exists $self->{setuid} ? $self->{setuid} : undef;
}

1;

__END__


=head1 NAME

Allssh - Module to login to multiple hosts via ssh and run a command

=head1 SYNOPSIS

BEGIN { unshift(@INC,"/home/seco/tools/lib") }

use Allssh;


# Defining a SIGINT handler allows the module destructor to do cleanup work if ^C interupts program its optional, but is handy to keep /tmp from getting cluttered

$SIG{INT} = sub {  exit; };


my $allssh = new Allssh;


# Host ranges can be specified as a string The output of CompressRange is acceptable (eg. $range = CompressRange( %range);  ) the command() method will block until all ssh's have completed


$allssh->command("j4011-j4020", "command");



#You can just dump out the output from the commands in a host:data type format

$allssh->print_output;


#or if you want to parse the output yourself you can by looking at the individual output files. The array returned two elements the host and the filename associated with its output.


foreach $i ( @{$allssh->outfiles()})  {
    my ($host, $file) = @{$i} ;
    print "$host: $file\n";
   }


=head1 DESCRIPTION

B<Allssh> is a module that allows you run run a command on multiple
hosts in parallel.     


=head1 OPTIONS

There are several variables that can be set to change the functionality
of the module.  There are methods setup to modify these values.
If called with arguments, they will return the current value.  If
an argument is specified, the value will be changed.  Defaults
are shown here:

=over 4 

=item $allssh->sshport(22)

=item $allssh->pingfirst(1);

Whether or not to try to ping the host before attempting to ssh. This should prevent excessive waiting on ssh to time out. Default is to try ping first.

=item $allssh=>maxflight(0);

How many maximum connections to have open at once.  Default is unlimited.  Good value might be "5" to avoid clobbering the host you're ssh'ing from.

=item $allssh=>maxtime(0);

How much time children processes are allowed to run before being terminated.

=item $allssh=>pause(0);

How long to pause between ssh connections.  Default is 0 and to spawn them as fast as it can.  This is useful for not overwhelming a server with NFS requests.

=item $allssh=>nodes2("");

Secondary range of nodes to iterate over in lockstep with the primary range.  Must be at least as long as the primary range.

=item $allssh->cleanup(1);

The module will cleanup the ssh output files as part of the DESTROY
method.  Default is to cleanup all files.


=item $allssh->sshport(22)

The module will, after each fork, and before each SSH, will 
setuid to the requested user ID.  This is designed so that 
root-ran allssh's will have the ability to demote themselves 
before running.


=item $allssh->sshbin( "/usr/sbin/ssh" );

Location of the ssh binary


=item $allssh->logdir( "/tmp/" );

Where to store temporary files


=item $allssh->logkey( "allssh" );

String to put into the output file name.  Example: /tmp/i2000.allssh.12345


=back

=head1 METHODS

=over 4

=item command($hosts, $command, @sshargs)

Handles the dirty work of spawning the command on a list of hosts.
If you include {} in the command portion it will be replaced by
the current hostname it is sshing to. @sshargs is an optional argument
containing flags to pass through to the ssh invocation.

Actually, {} has several forms:  {} = hostname; {i} = integer offset
starting at 0;  {me+100} will add 100 to the hostname (based on norby's
'me' script);  {q}, {sq}, {bq} produce ", ', and ` quotes.  "allssh.pl" has
one more option - {pwd} - that turns into the current
/net/sourcehost/pwd; however, that is not part of the module.

Example: $allssh->command("host1-host9", "grep {} /etc/hosts");
Example: $allssh->command("host1-host9", "grep {} /etc/hosts", '-t', '-2');





=item  outfiles();

Returns an array of the filenames the ssh output is stored in.
The array contains two elements, first being host, second being filename.

Example:

foreach $i ( @{$allssh->outfiles()})  {
    my ($host, $file) = @{$i} ;
    print "$host: $file\n";
   }



=item print_output();

Prints the contents of all the output files for you in a format
of host:data.  It will prepend that hosts hostname to each line
of output

Example: $allssh->print_putout();


=item $pid = Spawn($cmd, $host, $outputfile, @sshargs);

Should not be called directly unless you want to deal with the
process and output management yourself.  This method is used
internally to fork off the ssh processes.  It returns a PID of
the forked process. @sshargs is an optional list of extra args
that will be supplied to the ssh command.

=back


=head1 AUTHOR

Phillip Moore <pdm@inktomi.com)

=cut
