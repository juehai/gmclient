package Seco::FnSeco;
$VERSION = 2.0;

use strict;
use vars qw(@ISA @EXPORT @EXPORT_OK);
use Socket;
use IO::Socket;
use Symbol;
use Fcntl;
use POSIX qw(:errno_h);
use Carp;

# Daniel Muino's better range expander
use Seco::Range qw/expand_range range_set_altpath/;

use vars qw($Err $AltPath %rolling);
use vars qw(%callbys);


require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(
 &standardNodesParser 
 &fasterNodesParser
 &GetNodes &ExpandRange &CompressRange &CompressRangeBetter &IncNode &DecNode  &SortArrayByNode
 &ReadAll  &ReadData &ReadLine &open_tcp_socket 
 &GetNetInfo &GetVipInfo &GetIdpPort
 &sudo &GetGauge
 &SetAltPath
 &RollingAverage
 &get_host_addrs
);

@EXPORT_OK = qw( &CompareRange);
($AltPath) = grep(-d,qw(
  /home/tops/tools/conf
));
range_set_altpath($AltPath);



sub SortArrayByNode {
  return sort CompareRange @_;
}


  ###########################################################
  # standardNodesParse($opt_c,$opt_r,$opt_x);               #
  # Purpose: take arguments for -c, -r, and -x              #
  # Do automagical stuff to return back an array of nodes   #
  # This code is to become canonical                        #
  # -r and -x [ranges] will also support an extended syntax #
  #   g:*   will glob *                                     #
  #   c:foo will translate to cluster foo                   #
  ###########################################################


sub standardNodesParser {
  my($c,$r,$x,$sort) = @_;
  $sort = "yes" unless (defined $sort);

  my(@nodes,%x);
  if ($c) {
     @nodes = expand_range("\%$c");
  } else {
     @nodes = expand_range($r);
  }
  if ($x) {
     foreach ( &excludeRange($x) ) { $x{$_}++;}
     @nodes = grep( !defined $x{$_}, @nodes);
  }
  if ($sort =~ m#^(yes|1|slow|slower)#i) {
    @nodes = SortArrayByNode(@nodes);
  } elsif ($sort =~ m#^(2|fast|faster)$#) {
    @nodes = sort @nodes;
  }

  return @nodes;
}




sub excludeRange {
  my($r) = @_;
  return () unless (defined $r);
  if ($r =~ m/^g:(.*)$/) {
    return glob($1);
  } elsif ($r =~ m/^c:(.*)$/) {
    return &standardNodesParser($1,undef,undef);
  } else {
    return &standardNodesParser(undef,$r);
  }
}


sub sudo  {
  my($whoami,@sudo,$sudo);
  my($become) = @_;
  $become = "root" unless ($become =~ m/./);

  @sudo = ("/usr/local/bin/sudo",'/usr/bin/sudo');
  if ($^O =~ /linux/) {
   $whoami =`/usr/bin/whoami`;
  } else {
   $whoami = `/usr/ucb/whoami`;
  }
  chomp $whoami;

  if ($whoami =~ m/^$become$/) {
    return;
  }
  print "$whoami: This application needs '$become' priviledges.  Invoking sudo.\n";

  foreach (reverse @sudo) {
    $sudo = $_ if (-x $_);
  }
  unless (-x $sudo ) {
    print "ERROR: No sudo available in list @sudo\n";
    print "ERROR: su to $become, then rerun this command, or make sudo available\n";
    exit 1;
  }

  exec ($sudo, "-u",$become,$0, @main::ARGV) ||
    die "ERROR: exec returned, this wasn't supposed to happen!  Reason:  $!";
}



  ######################################################
  # from nodes.pl                                      #
  ######################################################


### Global variables
my($saved);  # hopefully this is safe global.
my (%CACHE_ProcessFile, %CACHE_GetNodes); # this is desired as global.
$saved = "";



###########################################################################
# @nodes = &GetNodes( $cluster, $type)
###########################################################################
# Takes as input the type of nodes ("ALL", "FE", or "CLUSTER")
# if there is no cluster specified, GetNodes will attempt to
# parse out $cluster in to the apropriate $type and range
###########################################################################
sub GetNodes
{
	my( $cluster) = $_[0];
	my( $type) = $_[1];

	if( !defined( $type))
	{
		if( $cluster =~ /:(.*)/)
		{
			$type = $1;
			$cluster =~ s/:(.*)//;
		}
		$type = "CLUSTER" if( !defined( $type));
	}

	return SortArrayByNode(expand_range("\%${cluster}:$type"));

}


###########################################################################
# $Id: //depot/manatee/main/tools/lib/read.pl#4 $
###########################################################################
# Defines functions that can be used to make non-blocking reads.
# First make a call to ReadAll to get all the data, then call
# ReadLine to get each line
###########################################################################

my( %BUFFER);

###########################################################################
# $ret = &ReadAll( $fh, $timout);
###########################################################################
# Reads in all the lines from the passed in file handle without blocking
# for more that $timeout seconds.
# Data is stored in $BUFFER{$fh}, and may be extracted via GetLine
#
# $ret = 0 if there was an error reading
# $ret = 1 otherwise
###########################################################################
sub ReadAll
{
	my( $timeout, $fh, $size);
	my( $rin, $ein, $rout, $eout, $timeleft);
	my( $nfound, @lines, $buffer, $tmp, $r);
	my( $start, $end, $ret);

	### Get arguments
	$fh      = $_[0];
	$timeout = $_[1];

	$size = 64;
	$ret = 1;

	$start = time;
	$end   = $start + $timeout;

	$buffer = "";
	### Store the data in the buffer
	if( !defined( $BUFFER{$fh}))
	{
		$BUFFER{$fh} = undef;
	}

	while( 1)
	{
		$timeout = $end - time;
		if( $timeout < 0)
		{
			### Incomplete Read
			$ret = 0;
			last;
		}

#		print "reading data from " . fileno( $fh) . "\n";
		$tmp = &ReadData( $fh, $size, $timeout);

		if( !defined( $tmp))
		{
			if( !defined( fileno( $fh)))
			{
#				print "EOF\n";
				### We're at EOF we're done reading
				last;
			} else {
#				print "TIMEOUT\n";
				### we timed out, and will return
				### with an incomplete read
				$ret = 0;
				last;
			}
		}
#		print "Read '$tmp'\n";

		### Append data we read to the buffer
		$buffer .= $tmp;

#		print "Done reading\n";
	}

	### Don't store data if we didn't read anything in
	unless( $buffer eq "")
	{
#		print "Storing lines for '$fh'\n";
		$BUFFER{$fh} .= $buffer;
	}

	return $ret;
}

###########################################################################
# $data = &ReadData( $fh, $size, $timeout);
###########################################################################
# Read data from the file handle waiting at most for the specified time
# $data = next block of data
# $data = undefined  on EOF or timeout.  if EOF, then $fh will be closed
# if $fh is closed, then fileno( $fh) will be undefined
###########################################################################
sub ReadData
{

	my( $fh, $size, $timeout);
	my( $rin, $rout, $ein, $eout);
	my( $buf, $read);


	$fh = $_[0];
	$size = $_[1];
	$timeout = $_[2];

	### Constructing the file handle vectors
	$rin = $ein = '';
	vec($rin,fileno($fh),1) = 1;
	$ein = $rin;

	### Make call to select.  Select will wait until
	### there is data to be read or we reach the timeout
#	print "Selecting with timeout of $timeout\n";
	select($rout=$rin, undef, $eout=$ein, $timeout);

	### If neither read nor error is set, then we timed out, and
	### will have to return with an incomplete read
	if( vec($eout,fileno($fh),1) == 0 &&
		vec($rout,fileno($fh),1) == 0) {
#		print "neither ERROR and READ set for \$fh - timeout\n";
		return undef;
	}

	$read = sysread( $fh, $buf, $size);

	### If we read no data, then we're at EOF
	if( !defined( $read) || $read == 0)
	{
#		print "EOF\n";
		close $fh;
		return undef;
	}

#	print "Read '$buf'\n";

#	print "Done reading\n";
	return $buf;
}

###########################################################################
# $line = &ReadLine( $fh, $timeout);
###########################################################################
# Reads from the filehandle the next available line of input.
# Uses data in $BUFFER{$fh} to store data read past the end of
# the line
###########################################################################
sub ReadLine
{
	my( $fh, $timeout);
	my( $buffer, $tmp, $line);
	my( $start, $end);

	$fh = $_[0];
	$timeout = $_[1];
	if( !defined( $timeout))
	{
		$timeout = 0;
	}

	### Get any data from a previous read
	if( exists( $BUFFER{$fh}))
	{
#		print "USING stored '\$buffer'\n";
		$buffer = $BUFFER{$fh};
	} else {
#		print "NOT USING stored '\$buffer'\n";
		$buffer = "";
	}

	$start = time;
	$end   = $start + $timeout;

	while( 1)
	{
#		print "--$buffer--\n";

		### If we've reached EOF
		if( !defined( $buffer) && !defined( fileno( $fh)))
		{
#			print "returning undefined\n";
			return undef;
		} elsif( defined( $buffer)) {
#			print "splitting \$buffer\n";
			### If we've read in a line
			if( $buffer =~ /^.*^/ && $buffer ne "")
			{
				($buffer, $tmp) = split( /^/, $buffer, 2);
#				print ">>$buffer<< ";
#				print ">>$tmp<<\n";
				if( defined( $tmp))
				{
					$BUFFER{$fh} = $tmp;
				} else {
					### If we've read all the data in the
					### buffer, there are 2 cases
					### If the file is closed, we're
					### done (return undef).  Otherwise
					### we want to keep reading, so store
					### the null string
					if( !defined( fileno( $fh)))
					{
						$BUFFER{$fh} = undef;
					} else {
						$BUFFER{$fh} = "";
					}
				}
#				print "read line\n";
				last;
			}
		}

		$timeout = $end - time;
		if( $timeout < 0)
		{

			### Incomplete Read
			if( $buffer !~ /[\n\r]$/)
			{
				### we might have leftover buffer, but timed out
				$BUFFER{$fh} = $buffer;
				$buffer = undef;
			}
			last;
		}

		$tmp = &ReadData( $fh, 64, $timeout);

		if( !defined( $tmp))
		{
			if( !defined( fileno( $fh)))
			{
#				print "EOF\n";
				### We're at EOF we're done reading
				return undef;
			} else {
#				print "TIMEOUT\n";
				### we timed out, and will return
				### with an incomplete read
				return undef;
			}
		}
		$buffer .= $tmp;
	}
#	print "DONE! '$buffer'\n";
	if( $buffer !~ /[\n\r]$/)
	{
		### we might have leftover buffer, but timed out
		$BUFFER{$fh} .= $buffer;
		$buffer = undef;
	}
	return $buffer;
}

  ######################################################
  # from tcp_sock.pl                                   #
  ######################################################

###########################################################################
# $Id: //depot/manatee/main/tools/lib/tcp_sock.pl#15 $
###########################################################################
# Defines functions that can be used to open and use tcp sockets
#
# These functions are not IPv6 compliant.
###########################################################################


# mode 1 = buffering, 0 = no buffering
sub set_buffering_mode
{
  my ($fh, $mode) = @_;

  my $orig_handle = select ($fh);
  $| = ($mode == 0);
  select ($orig_handle);
}

# mode 1 = blocking, 0 = non-blocking
sub set_blocking_mode
{
  my ($fh, $mode) = @_;
  my $flags = fcntl ($fh, F_GETFL, 0);
  my $newflags = ($mode
                  ? $flags & ~(O_NONBLOCK)
                  : $flags | O_NONBLOCK);

  fcntl ($fh, F_SETFL, $newflags)
    if ($flags != $newflags);
}


# Convert integers from host byte order to network byte order.
# Network byte order is big-endian.
sub htonl
{
  return $_[0] unless (unpack ("c2", pack ("i", 1)));
  return pack ('C4', reverse unpack ('C4', $_[0]));
}

# Note that ntohl is identical to htonl.
*ntohl = \&htonl;

sub ipaddr_aton
{
  my $addr = shift;

  return $addr unless ($addr =~ /^\d+$/o);

  # String is in 255.255.255.255 format
  return pack ('C4', split (/\./, $addr))
    if (index ($addr, ".") >= 0);

  # If string is not in octet form but instead is a flat ascii IP,
  # then just convert it to network byte order.
  # Convert addr to the dotted decimal representation for it.
  #
  # source IP addresses are specified in this flat format in the
  # IRC DCC protocol; I don't know if it's common anywhere else.
  htonl (pack ("I", $addr));
}

sub ipaddr_ntoa
{
  join (".", unpack ("C4", $_[0]));
}

sub get_host_addrs
{
  my $hostname = shift;
  my @addrs = gethostbyname ($hostname);
  return undef
    unless (defined $addrs[0] && $addrs[0] ne "");
  splice (@addrs, 0, 4);
  map { ipaddr_ntoa ($_) } @addrs;
}



###########################################################################
# $status = &open_tcp_socket( $socket, $host, $port, $timeout)
###########################################################################
# Opens a socket to the port on the machine.
#
# returns 0 if failure, and sets the $Err variable to the error code
###########################################################################
sub open_tcp_socket
{
  my ($fh, $host, $port, $timeout) = @_;
  my ($name, $aliases, $proto) = getprotobyname ('tcp');
  my $addr = ($host =~ /^\d+$/o
              ? ipaddr_aton ($host)
              : (gethostbyname($host))[4]);

  if (!defined $addr || $addr eq "") {
    $Err = "$host: Unknown host";
    return 0;
  }

  unless (socket ($fh, PF_INET, SOCK_STREAM, $proto)) {
    $Err = "socket: $!";
    return 0;
  }

  # Temporarily put socket in non-blocking mode so that we can use a
  # user-defined connection timeout below.
  set_blocking_mode ($fh, 0);
  unless( connect ($fh, sockaddr_in ($port, $addr))) {
    unless( $! == 0 || $! == EINPROGRESS ) {
      $Err = "connect: $!";
      return 0;
    }
  }


  my $tmout = (defined $timeout ? $timeout : 1);
  my $wbits = '';
  vec ($wbits, fileno ($fh), 1) = 1;
  if (select (undef, $wbits, undef, $tmout) != 1) {
    $! = ETIMEDOUT;
    $Err = "connect: $!";
    return 0;
  }

  # We got an event before timeout, but don't know what kind.
  # Check to make sure the connection actually succeeded.
  my $so_error = getsockopt ($fh, SOL_SOCKET, SO_ERROR);
  if (defined $so_error && unpack ('i', $so_error) != 0) {
    $! = unpack ('i', $so_error);
    $Err = "connect: $!";
    return 0;
  }

  set_blocking_mode ($fh, 1);
  set_buffering_mode ($fh, 0);
  return 1;
}



###########################################################################
# %range = ExpandRange( $range);
###########################################################################
# Takes a range, and returns a hash of each element in the range, such that
# $range{$key} = 1
###########################################################################
sub ExpandRange
{
	my ($range, %symbols) = @_;
	my @nodes = expand_range($range);
	return map { $_ => 1 }  @nodes;
}


###########################################################################
# $range = CompressRangeBetter( %range);
###########################################################################
# Takes a hash of each element in the range, such that $range{$key} = 1
# and returns a string representing the compression of the range into
# a more concise format
# "Better" version also condenses by domain, such as {foo,bar}.domain 
# but the output may need quoting if pasting in a shell
###########################################################################

sub CompressRangeBetter {
   my($key,$value, %HoH,$r,@r);
   while($key = shift @_) {
      $value = shift @_;
      my($left,$right) = split(/\./,$key,2);
      if ($key =~ m/^[0-9.]+$/) {
         $left = $key; $right = undef;
      }
      $left = "" if (! defined $left);
      $right = "" if (! defined $right);
      $HoH{$right}{$left}=1;
   }
   my $domain;
   foreach $domain (sort keys %HoH) {
     my $r = CompressRange( %{$HoH{$domain}});
     if (length($domain)) {
       $r = "{$r}.$domain";
     }
     push(@r,$r);
   }
   return(join(",",@r));
}


###########################################################################
# $range = CompressRange( %range);
###########################################################################
# Takes a hash of each element in the range, such that $range{$key} = 1
# and returns a string representing the compression of the range into
# a more concise format
###########################################################################
sub CompressRange
{
	my( %range);
	my( $ret, $first, $next, $cur, $node);

	%range = @_;
	$first = "";
	$ret = "";

	foreach $node (sort CompareRange (keys %range))
	{
		if( $first eq "")
		{
			$first = $node;
			$next = &IncNode( $node);
		} elsif( $node eq $next) {
			$next = &IncNode( $next);
		} else {
			$next = &DecNode( $next);
			$ret .= "," if( $ret ne "");
			if( $first eq $next)
			{
				$ret .= "$first";
			} else {
				$ret .= "$first-$next";
			}
			$first = $node;
			$next = &IncNode( $node);
		}
	}
	$next = &DecNode( $next);
	$ret .= "," if( $ret ne "");
	if( $first eq $next)
	{
		$ret .= "$first";
	} else {
		$ret .= "$first-$next";
	}
	return $ret;
}

###########################################################################
# $next = &IncNode( $node);
###########################################################################
# Increments a node such that it would be the next in the series
###########################################################################
sub IncNode
{
	my( $a, $an, $as, $len);

	$a = $_[0];

	my($domain) = "";
        if ($a !~ m/^[\d.]+$/) {   # not IP or raw number
           if ($a =~ m/^([^.]*?\d+)(\..*)$/) {
               $domain = $2;  $a = $1;    # Strip the domain
           }
        }


	if( $a =~ /^(.*?)(\d+)$/)
	{
		$as = $1;
		$an = $2;

#print "$as<->$an\n";
		### $as might be undefined
		$as = "" unless( defined( $as));

		$len = length( $an);
		$an++;
#printf("I\t%s%0${len}d <- $a\n", $as, $an);
		return (sprintf("%s%0${len}d", $as, $an) . $domain);
#		return "$as$an";
	}
	return $a . $domain;
}

###########################################################################
# $next = &DecNode( $node);
###########################################################################
# Decrements a node such that it would be the previous in the series
###########################################################################
sub DecNode
{
	my( $a, $an, $as, $len);

	$a = $_[0];

	my($domain) = "";
        if ($a !~ m/^[\d.]+$/) {   # not IP or raw number
           if ($a =~ m/^([^.]*?\d+)(\..*)$/) {
               $domain = $2;  $a = $1;    # Strip the domain
           }
        }


	if( $a =~ /^(.*?)(\d+)$/)
	{
		$as = $1;
		$an = $2;

		### $as might be undefined
		$as = "" unless( defined( $as));

		$len = length( $an);
		$an--;
#printf("D\t%s%0${len}d <- $a $len($an)\n", $as, $an);
		return (sprintf("%s%0${len}d", $as, $an) . $domain);
#		return "$as$an";
	}
	return $a . $domain;
}

###########################################################################
# &CompareRange()
###########################################################################
# Compares two elements of range, and determines which should
# be sorted before the other
###########################################################################
sub CompareRange
{
	my( $as, $an, $bs, $bn);
	my($aa,$bb) = ($a,$b);

	unless ($aa =~ m/^[\d.]+$/) {
		if ($aa =~ m/^([^.]*?\d+)(\..*)$/) {
			my $strip = "\Q$2";
			$aa =~ s/$strip$//;
			$bb =~ s/$strip$//;
          	}
        }


	if( $aa =~ /^(.*?)(\d+)$/o)
	{
		$as = $1;
		$an = $2;

		if( $bb =~ /^(.*?)(\d+)$/o)
		{
			$bs = $1;
			$bn = $2;

			if( !defined($as) || !defined( $bs))
			{
				return $an <=> $bn;
			}

			if( $as eq $bs)
			{
#				print "returning $an <=> $bn\n";
				return $an <=> $bn;
			} else {
#				print "returning $as <=> $bs\n";
				return $as cmp $bs;
			}
		}
	}
#	print "returning $a <=> $b\n";
	return $a cmp $b;
}


  ######################################################
  # from net.pl                                        #
  ######################################################

###########################################################################
# $Id: //depot/manatee/main/tools/lib/net.pl#8 $
###########################################################################
# Defined GetNetInfo which can be used for extracting information
# about a clusterts network configuration
###########################################################################

###########################################################################
# %info = &GetNetInfo( $cluster)
###########################################################################
# Takes as input the cluster in question
###########################################################################
sub GetNetInfo
{
# snoop confirms that this routine is called by watchers and such
        my( $cluster) = $_[0];
	my( $type, $full, $key);
        my( $file, %info, $dir);

	if( $cluster =~ /(.*):(.*)/)
	{
		$full = $cluster;
		$cluster = $1;
		$type = $2;
	}

        ($dir) = grep(-f "$_/net.cf",(
           "/home/seco/tools/conf/$cluster",
	   # search pe maybe have some problems.
           "/home/admin/tools/conf/$cluster",
           "$AltPath/$cluster/tools/conf",
           "$AltPath/$cluster"));

	$dir ||= "/home/seco/tools/conf/$cluster";
	unless( -d $dir)
	{
		die "ERROR: no cluster directory found at '$dir'";
	}

        $file = "$dir/net.cf";

	%info = &GetConfInfo( $file);

	### Much with the keys if necessary
	if( defined($type))
	{
		foreach $key (keys %info)
		{
			if( defined( $info{"$key:$type"}))
			{
				$info{$key} = $info{"$key:$type"};
			}
		}
	}

	return %info;
}


###########################################################################
# $port = &GetIdpPort( $cluster)
###########################################################################
# Takes as input the cluster in question
###########################################################################
sub GetIdpPort
{
	my ($cluster) = (@_);
        $cluster =~ s/:.*//;  # Remove any subtypes
	my %info = GetNetInfo(@_);
	unless (defined $info{"PORT"}) {
           if ($cluster =~ m/^[fkmwx]g[0-9]0([0-9])$/) {
                $info{"PORT"} = 55554 + $1;
           };
	}
	$info{"PORT"} ||= 55555;
 	return $info{"PORT"};
}




###########################################################################
# %info = &GetVipInfo( $cluster)
###########################################################################
# Takes as input the cluster in question
###########################################################################
sub GetVipInfo
{

        my( $cluster) = $_[0];
        my( $file, %info, $dir);

        ($dir) = grep(-f "$_/vips.cf",(
           "/home/seco/tools/conf/$cluster",
           "$AltPath/$cluster/tools/conf",
           "$AltPath/$cluster"));

	$dir ||= "/home/seco/tools/conf/$cluster";
#        $dir = "/home/seco/tools/conf/$cluster";
        unless( -d $dir)
        {
                die "ERROR: no cluster directory found at '$dir'";
        }

        $file = "$dir/vips.cf";

        %info = &GetConfInfo( $file);

        return %info;
}

###########################################################################
# $Id: //depot/manatee/main/tools/lib/conf.pl#2 $
###########################################################################
# Parses a key/value pair based conf file, and returns the results
###########################################################################

###########################################################################
# %info = &GetConfInfo( $file)
###########################################################################
# Takes as input the cluster in question
###########################################################################
sub GetConfInfo
{
# snoop confirms that this routine is called by watchers and such
	my( $file, %info, $line);

	$file = $_[0];

	unless( -f "$file")
	{
		die "ERROR: no such file '$file'";
	}

        if( open( CONF, "$file") == 0)
        {
                die "ERROR: could not open file '$file' $!";
        }

        while( defined( $line = <CONF>))
	{
		next if( $line =~ /^\s*#/);
		$line =~ s/(#.*)//;
		if( $line =~ /\s*(\S+)\s+(.*)/)
		{
			$info{$1} = $2;
		}


#		print $line;
	}
	close CONF;

	return %info;
}

sub GetGauge {
  my($cluster,$grep,$alarm,$mode) = @_;
  my @return;
  my $line;
  my %info = &GetNetInfo( $cluster);
  my ($host, $port) = split( /:/, $info{GAUGE});
  ($port) = split( /,/, $port);
  my $remote;

  $port += 2000 if ((defined $mode) && ($mode =~ m/^(fast|1)/i));
  

  $remote = IO::Socket::INET->new(Proto=>"tcp",PeerAddr=>$host,PeerPort=>$port,Timeout=>($alarm ? $alarm : 10));
  unless ($remote) {
     die "Unable to connect to $host port $port: $!\n";
  }
  alarm $alarm if ($alarm);
  while($line = <$remote>) {
    chomp $line;
    $line =~ s/\s+/:/g;
    push(@return,$line) if ($line =~ /$grep/);
    last if ($line =~ /^T:\d+/);
    last if ($line =~ /^#MM:/);
  }
  close $remote;
  alarm(0) if ($alarm);
  return @return;
}

sub SetAltPath {
 my ($newpath) = @_;
 if (defined $newpath) { $AltPath = $newpath ; }
 range_set_altpath($AltPath);
 return $AltPath;
}

sub RollingAverage {
  my($label,$value,$size) = @_;
  my($count,$total,$average);
  $size ||= 10;
  if (defined  $rolling{$label} ) {
    $count = 0;
    $total = 0;
    foreach (@{  $rolling{$label} }) {
      next if ((!$total) && (! ($_ + 0)));
      $total += $_;
      $count++;
    }
    $count ||= 1; # Just in case
    $average = $total / $count;
  } else {
    $average = $value;
  }
  push(@{  $rolling{$label} }, $value);
  shift @{  $rolling{$label} } if (scalar (@{  $rolling{$label} }) > $size);
  return $average;
}

if (defined $ENV{"SECOALTPATH"}) {
  SetAltPath($ENV{"SECOALTPATH"});
}


sub snoop {
 my ($package, $filename, $line, $subroutine, $hasargs,
                   $wantarray, $evaltext, $is_require, $hints, $bitmask) = caller(1);
 $callbys{"${filename}:$line calls $subroutine"}++;
}


END {
  my $message = "program=$0|";
  my $key;
  return if ($0 =~ m#allmanateed.pl#);   # We already recorded what this does in the comments below the snoop() calls
  return if ($0 =~ m#/home/watcher/watcher3/dnServer/dn-check#); # only calls functions via AllManateed.pm

  return unless (scalar keys %callbys);  # don't do anything

  foreach $key (sort keys %callbys) {
    $message .= "$key $callbys{$key} |";
  }
  if (length($message) > 500) {
    $message = substr($message,0,500) . '!';
  }
  $message .= "\n";


 my $proto = getprotobyname('udp');
 socket(Socket_Handle, PF_INET, SOCK_DGRAM, $proto) or return;
 my $iaddr = gethostbyname('pain.inktomisearch.com');
 my $port = 7326; # SECO
 my $sin = sockaddr_in($port, $iaddr);
 send(Socket_Handle, $message, 0, $sin) or return;
 return;
}


1;
