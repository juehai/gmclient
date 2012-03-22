#!/usr/bin/perl

use Getopt::Std;			        # for getopts()
use strict;					# prevent typos
use FindBin '$Bin';				# locate the libraries
use POSIX ":sys_wait_h";

use Seco::FnSeco;
#use Seco::Range;

#require "nodes.pl";				# for GetNodes()
#require "range.pl";				# for ExpandRange()

my( $arg, @temp, @nodes, $node, %nodes, $index, $thiscmd, $cmd, $i);
my( $cluster, @x_nodes, %x_nodes, $rc);
my( $pid, %pids, %outfile, $counter, $errors, %killat, %killwarned);

#############################################################################
# Get arguments
#############################################################################
use vars '$opt_h','$opt_c', '$opt_r', '$opt_R', '$opt_n', '$opt_p', '$opt_l', '$opt_L','$opt_x', '$opt_f', '$opt_g', '$opt_m', '$opt_v', '$opt_q', '$opt_s', '$opt_z', '$opt_I', '$opt_Q', '$opt_N', '$opt_e';

if(!(getopts("N:hnlevqc:r:Rg:plLx:f:m:s:z:IQ")) || $opt_h || (!$opt_r && !$opt_c && !$opt_I && !$opt_g) || (!$opt_n && !$opt_l && !$opt_L && $#ARGV < 0)) {
	if ($opt_r && ! $opt_l) {
		$opt_l = 1;
	} else {  # ZZTOP
        print STDERR "Usage: $0 [-h] [-c <cluster>] [-r <range>] [-x <nodes>] [-l] [-p] [-n] <command>\n";
	print STDERR "\tExecute the command once for each node in the cluster\n";
	print STDERR "\tsubstituting '{}' for the name of the node\n";
	print STDERR "\t-h displays this help information\n";
	print STDERR "\t-c specifies a cluster to operate on.  May be of the\n";
	print STDERR "\t   form cluster or cluster:TYPE[RANGE] (i.e. sc3 or sc3:CLUSTER or sc3:CLUSTER[0-9].)\n";
	print STDERR "\t-l only list nodes (or -L for better compression).\n";
	print STDERR "\t-e print expanded list to STDOUT (one node per line)\n";
	print STDERR "\t-n only display count of nodes.\n";
	print STDERR "\t-p obsolete\n";
	print STDERR "\t-r specifies a range to be operated on\n";
        print STDERR "\t-I read STDIN for raw list of targets, no seco expansion\n";
	print STDERR "\t-R pseudo-randomize target list\n";
	print STDERR "\t-x excludes nodes.\n";
	print STDERR "\t-g use instead of -r or -x - will glob()\n";
	print STDERR "\t-f perl printf format code - ie %02s.\n";
        print STDERR "\t-m Auto-background jobs; up to max -m # at once\n";
	print STDERR "\t-v verbose mode for -m\n";
	print STDERR "\t-q don't print out exclude information for -l\n";
	print STDERR "\t-s sleep seconds between jobs (handy with -m to stagger)\n";
        print STDERR "\t-z after # seconds, kill job (requires -m)\n";
        print STDERR "\t-Q Print only errors, try and be otherwise quiet\n";
        print STDERR "\t-N 100 Run command for N hosts, replace {} with -r RANGE\n"; 
        doExit(-1);
	} # ZZTOP plays real gud
}

my $tmpdir = exists $ENV{TMPDIR} ? $ENV{TMPDIR} : "/tmp";
   $tmpdir = "/tmp" unless (-d $tmpdir);


$opt_q = 1 if ($opt_Q);

#############################################################################
# Build up the node list
#############################################################################
if ($opt_I) {
  @nodes = grep(/./,<STDIN>);
  foreach (@nodes) { chomp; } 
} elsif ($opt_g) {
   @nodes = glob($opt_g);
} elsif( $opt_c) {
	### Get the cluster nodes
	@nodes = &GetNodes( $opt_c);
} elsif( $opt_r) {
	### Get the correct nodes
	#%nodes = &ExpandRange( $opt_r);
	%nodes = &ExpandRange( $opt_r);
	@nodes = SortArrayByNode (keys( %nodes));
} else {
	### Old syntax
	while( $arg = shift( @ARGV))
	{
		last if( $arg eq "-cmd");

		%nodes = &ExpandRange( $arg);
		@temp = sort {$a <=> $b} (keys( %nodes));
		push(@nodes, @temp);
	}
	@nodes = SortArrayByNode (@nodes);
}

if ($opt_N) {
  my @nodelist = @nodes;
  @nodes = ();
  while (scalar @nodelist) { 
    my @batch  = splice(@nodelist,0,$opt_N);
    my $range = CompressRange(map{$_=>1} @batch);
    push(@nodes,$range);
  }
}

if( $opt_x)
{
	if( $opt_x =~ /^c:(.*)/)
	{
		print "excluding cluster $1\n" unless (defined $opt_q);
		my( $cluster);
		$cluster = $1;

		@x_nodes = &GetNodes( $cluster);
		foreach $node (@x_nodes)
		{
			$x_nodes{$node} = 1;
		}
	} elsif( $opt_x =~ /^g:(.*)/) {
		print "excluding glob $1\n" unless (defined $opt_q);
		my( $glob);
		$glob = $1;

		@x_nodes = glob($glob);

		foreach $node (@x_nodes)
		{
			$x_nodes{$node} = 1;
		}
	} else {
		print "excluding nodes $opt_x\n" unless (defined $opt_q);

		%x_nodes = &ExpandRange( $opt_x);
	}
	@temp = @nodes;
	@nodes = ();
	foreach $node( @temp)
	{
		push( @nodes, $node) if( !exists( $x_nodes{$node}));
	}
}

if ($opt_R) {
#  my(%n) =         %nodes = &ExpandRange( $opt_R);
#  @nodes = grep($n{$_},@nodes);
   randomize();
}


### Verfiy that we have nodes
if( $#nodes <0)
{
	die "ERROR: No nodes specified";
}

### if -n, then print out node count
if( $opt_n)
{
	$index = $#nodes+1;
	print "$index nodes specified.\n";
	doExit(0);
}

### -e like standardNodesParser -e
if ($opt_e) {
    map { print $_, "\n" } @nodes;
    doExit(0);
}

### if -l, then print out nodes
if( $opt_l)
{
	%nodes = ();
	foreach $node (@nodes)
        {
		$nodes{$node} = 1;
	}
 	print &CompressRange( %nodes);
	print "\n";
	
	doExit(0);
}

### if -L , print out the nodes -but with domain compression (output may require quotes!)
if( $opt_L)
{
	%nodes = ();
	foreach $node (@nodes)
        {
		$nodes{$node} = 1;
	}
        print "\"";
 	print &CompressRangeBetter( %nodes);
	print "\"\n";
	
	doExit(0);
}



if (($opt_z) && (! $opt_m)) {
  print "WARNING: Using -z requires -m 1 (or better); using -m 1\n";
  $opt_m = 1;
}

### Print out all nodes up front
unless ($opt_Q) {
print STDERR "Nodes:";
  foreach $node (@nodes)
  {
  	print STDERR " $node";
  }
  print STDERR "\n";
  print STDERR $#nodes+1, " nodes specified\n";
}
$|= 1;
$index= 0;

### Build up command
foreach $arg (@ARGV) {
    $cmd .= "$arg ";
}
chomp($cmd);
print STDERR "Command: $cmd\n" unless ($opt_Q);

my $nohang = ($opt_z) ? &WNOHANG : 0;

### Iterate over all the nodes
foreach $node (@nodes)
{
	print STDERR "$node " unless ($opt_Q);

 	if ($opt_f =~ m/./) {
	   $node = sprintf $opt_f, $node;
	}

	$thiscmd= $cmd;
 	$thiscmd =~ s/{{([a-z]*)}}/\xff\xff$1\xff\xff/g;
	$thiscmd =~ s/{}/$node/g;
	$thiscmd =~ s/{i}/$index/g;
        $thiscmd =~ s/{q}/"/g;
        $thiscmd =~ s/{sq}/'/g;
        $thiscmd =~ s/{bq}/\`/g;
        $thiscmd =~ s/\xff\xff([a-z]*)\xff\xff/{$1}/g;

        if (!$opt_m) {

        	### Brianm's cool hack to trap and return the ^C from our subprocess
        	### exit code 2 is the ^C (SIGINT) exit code
        	$rc = system("/bin/sh",
        		"-c",
        		"handler ( ) { exit 2 ; } ;  trap handler 2 ; $thiscmd");

        	### We only care about the program portion of the return code
        #	printf( "returned %04d $?\n", $rc);
        	$rc /= 256;
        #	printf( "returned %04d\n", $rc);

        	### Check for control C 
        	if( ($rc & 0x00ff) == 2)
        	{
                        warn "$0: $node generated an exit-code! SIGINT\n";	
			$errors++;
        		sleep 1;
        	} elsif( $rc) {
        		warn "$0: $node generated an exit-code!\n";
			$errors++;
        	}
		sleep($opt_s) if ($opt_s);

        } else {
		print "Background: $thiscmd\n" if ($opt_v);
		my $outfile = "${tmpdir}/fornode.$node.$$";
		if ($node =~ m#(.*)/(.*?)$#) {
			# This is likely a -g global match using subdirs
			# like: fornode.pl -g "*/*" ...
			my $node_dir = "${tmpdir}/fornode.$$/$1";
			$outfile = "${tmpdir}/fornode.$$/$node";
			#printf("mkdir -p $node_dir\n");
			system("mkdir -p $node_dir");	# Don't check return
		}
		$pid = Spawn($thiscmd,$outfile);
		$pids{$pid}=$node;
		$outfile{$pid}=$outfile;
		if ($opt_z) {
			$killat{$pid}=time + $opt_z;
		}
		$counter++;
		sleep ($opt_s) if ($opt_s);
		while ($counter >= $opt_m) {
			$pid = waitpid(-1,$nohang);
			if ($pid == 0) {
				sleep 1;
				checkkillat();
				next;
			}
			if ($pid != -1) {
				print STDERR "INFO: $pids{$pid} completed\n" unless ($opt_Q);
				my $code = ($? >> 8);
                                my $signal = ($? && 0x7f);
				if ($code) {
					print STDERR "ERROR: $pids{$pid} completed with error code $code - $outfile{$pid}\n";
					$errors ++;
				} elsif ($signal) {
					print STDERR "ERROR: $pids{$pid} completed with signal $signal - $outfile{$pid}\n";
					$errors ++;
                                } else {
					unlink($outfile{$pid});
				}
				$counter--;
			}
		}
        }

	$index++;
}

if ($opt_m) {
 print STDERR "Waiting\n" if ($opt_v);
 while (($pid = waitpid(-1,$nohang)) != -1) {
	if ($pid == 0 ) {
		sleep 1;
		checkkillat();
		next;
	}
 	print STDERR "INFO: $pids{$pid} completed\n" unless ($opt_Q);
	my $code = ($? >> 8);
	my $signal = ($? && 0xff);
 	if ($code) {
		print STDERR "ERROR: $pids{$pid} completed with error code $code - $outfile{$pid}\n";
		$errors ++;
 	} elsif ($signal) {
		print STDERR "ERROR: $pids{$pid} completed with signal $signal - $outfile{$pid}\n";
		$errors ++;
	} else {
		unlink($outfile{$pid});
	}
 	$counter--;
 }
}


print STDERR "\n" unless ($opt_Q);

&doExit;


sub checkkillat {
  my $now = time;
  foreach $pid (keys %killat) {
	my $when = $killat{$pid};
	if (! -d "/proc/$pid") {
		delete $killat{$pid};
		next;
	}
	if (($now > $when + 5) && ($killwarned{$pid})) {
		print STDERR "KILL: Sending a kill -9 $pid for $pids{$pid}\n";
		kill(9, $pid);
		open(WARN,">>$outfile{$pid}"); 
		print WARN "Sending kill -9 (took too long)\n";
		close WARN;

	} elsif (($now > $when) && (!$killwarned{$pid})) {
		print STDERR "KILL: Sending a kill -15 $pid for $pids{$pid}\n";
		kill(15, $pid);
		$killwarned{$pid}++;
		open(WARN,">>$outfile{$pid}"); 
		print WARN "Sending kill -15 (took too long)\n";
		close WARN;
	}
  }
}

sub Spawn
{
    my($cmd, $outfile) = @_;
    my($i, $tmpstr, $pid, $host, $code);


    ### Fork off a new process
    $pid = fork;
    die "ERROR: can't fork process $!\n" unless (defined($pid));

    if ($pid) {
        ### original process comes here
        return $pid;
    } else {
        ### Child Process
        open(STDOUT, ">$outfile") || die "Can't redirect stdout to \"$outfile\"";
		open(STDERR, ">&STDOUT") || die "Can't redirect stderr to \"$outfile\"";

        ### OK, let's do it
        exec( $cmd);
    }
    ### This code is actually never reached
    return $pid;
}


##  If a code is passed,  exit with that code,  
##  otherwise exit with $errors

sub doExit {
  exit $_[0] if (defined ($_[0]));
  # clean up temp dir upon clean exit
  system("rm -rf ${tmpdir}/fornode.$$") if ($errors == 0);
  exit $errors;
} 



sub randomize {
        @nodes =
                map { $_->[0] }
                sort { $a->[1] cmp $b->[1] }
                map { [ $_, substr($_,-1,1) ] } @nodes;
}

