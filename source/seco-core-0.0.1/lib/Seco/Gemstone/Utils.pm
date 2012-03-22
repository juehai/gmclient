package Seco::Gemstone::Utils;

use strict;
use Exporter;
use FindBin qw/$Bin/;
use File::Copy;
use Sys::Hostname;
use Socket;
use Seco::Gemstone::Logger qw(log);
use Carp;
use Fcntl;

our @ISA = qw/Exporter/;
our @EXPORT_OK = qw/gem_all_groups gem_read_raw_file gem_read_gzip_raw_file
    read_file write_file write_template gem_copy gem_move motd expand_vars
    get_rel_glob/;


eval {
    require Seco::AwesomeRange;
    import Seco::AwesomeRange qw/expand_range range_set_altpath/;
    log("debug", "Using Seco::AwesomeRange");
};
if ($@) {
    require Seco::Range;
    import Seco::Range qw/expand_range range_set_altpath/;
    log("warning", "Can't find AwesomeRange - using Seco::Range");
}


{
    my $_hostname;
    my $_boothost;
    my $_adminhost;
    sub get_hostname {
	return $_hostname if $_hostname;
	return $_hostname = hostname();
    }
    sub get_boothost {
	return $_boothost if $_boothost;
        eval {
                ($_boothost) = expand_range('^' . get_hostname());
        };
        return $_boothost if $_boothost;


	my $etchosts = read_file("/etc/hosts");
	my @boothost_line = grep {/\bboothost\b/} split("\n", $etchosts);
	unless (@boothost_line) {
	    return $_boothost = "pain.inktomisearch.com";
	}
	my $ip = (split ' ', $boothost_line[0])[0];
	my $name = gethostbyaddr(inet_aton($ip), AF_INET);
	return $_boothost = $name;
    }
    sub get_adminhost {
	return $_adminhost if $_adminhost;
        eval {
                ($_adminhost) = expand_range('^' . get_hostname());
        };
        return $_adminhost;
    }
}

=over 4

=item get_rel_glob <glob>

Return the glob pattern relative to raw/

=cut
sub get_rel_glob {
    my $glob = shift;
    return (substr($glob, 0, 1) eq "/") ? $glob : "$Bin/../raw/$glob";
}

=item @groups = gem_all_groups

Get all groups in groups.cf, respecting the order in the file

=cut
sub gem_all_groups {
    my @groups;
    open my $fh, "$Bin/../conf/groups.cf" or die "conf/groups.cf: $!";
    while (<$fh>) {
	s/#.*$//;
	next unless /^\S/;
	s/\s+$//;
	push @groups, $_;
    }
    close $fh;

    return @groups;
}

=item $contents = gem_read_gzip_raw_file("ssh_known_hosts.gz")

Read a raw/* file, gunzip it, and return the contents in an array

=cut

sub gem_read_gzip_raw_file {
  my $file = shift;
  my $fh;
  my $filename = substr($file,0,1) eq "/" ? $file : "$Bin/../raw/$file";

  # Handle ::boothost:: etc in filename
  if ($filename =~ m/::/) {
     my ($newfilename) = expand_vars($filename);
     if (! -f $newfilename) {
        log("warning", "no $newfilename, treating as empty");
        return();
     }
     $filename = $newfilename;
  }
  open $fh, "gunzip -c $filename|" or die "gunzip -c $filename: $!";
  my @results = <$fh>;
  close $fh;
  chomp(@results);
  return @results;
}

=item $contents = gem_read_raw_file("passwd")

Read a raw/* file, returning the contents in an array
Note: this parses  ::shortname:: ::hostname:: ::adminhost::
and if seen, will make this OPTIONAL and NON FATAL

=cut
sub gem_read_raw_file {
    my $file = shift;
    my $fh;
    my $filename = substr($file,0,1) eq "/" ? $file : "$Bin/../raw/$file";

    # Handle ::boothost:: etc in filename
    if ($filename =~ m/::/) {
       my ($newfilename) = expand_vars($filename);
       if (! -f $newfilename) {
          return();
       }
       $filename = $newfilename;
    }
    open $fh, "<$filename" or die "$filename: $!";
    my @results = <$fh>;
    close $fh;
    chomp(@results);
    return @results;
}

=item $contents = read_file("/etc/motd")

Read a file returning its contents as a scalar

=cut
sub read_file {
    my $file = shift;
    sysopen my $fh, $file, 0 or do {
	log("warning", "$file: $!");
	return;
    };
    sysread $fh, my $results, -s $fh || 4096; # use 4k for /proc files
    close $fh;
    return $results;
}

sub write_template {
    my ($file, $contents) = @_;
    write_file($file, expand_vars($contents));
}

sub write_file {
    my ($file, $contents) = @_;
    my $error = 0;
    confess "write_file needs a filename and some contents" unless
	defined $file and defined $contents;

    my $work_file = "$file.gemclient$$";
    unlink $work_file;
    sysopen(my $fh, $work_file, O_WRONLY | O_CREAT | O_EXCL)
        or die "$file: $!\n";
    my $n = syswrite($fh, $contents);
    $error = $n != length($contents);
    close $fh or $error = 1;

    if ($error) {
        log("warning", "Errors writing $file. Not touching.");
        unlink "$file.gemclient$$";
    } else {
        unlink $file;
        gem_move("$file.gemclient$$" => $file) or 
            log("warning", "Moving $file.gemclient$$ -> $file");
    }
}

sub gem_move {
    my ($from, $to) = @_;
    unless (move($from, $to)) {
	log("warning", "$to: $!");
	return;
    }
    return 1;
}

sub gem_copy {
    my ($from, $to) = @_;
    unless (copy($from, $to)) {
	log("warning", "$to: $!");
	return;
    }
    return 1;
}

sub get_my_ip {
    my $prev_path = $ENV{"PATH"};
    $ENV{"PATH"} = "/bin:/sbin:/usr/bin:/usr/sbin";
    my $ifconfig = `ifconfig -a`;
    $ENV{"PATH"} = $prev_path;
    $ifconfig =~ s/\n / /g;
    my @ifconfig = split( /\n/, $ifconfig );

 foreach (@ifconfig) {
   next if (/lo:/);            # Don't want loopbacks
   next if (/dummy/);            # Don't want dummies
   next if (/HWaddr 00:00:00:00:00:00/); # Don't want dummy interfaces
   next if (/^eth\d:/);        # Don't want vips
   next if (/inet addr:10\./); # Don't want private IP
   next if (/inet addr:127\./);# Don't want loopback
   if (/inet addr:(\S+)/) {
     return $1;
   }
 }
 return undef;
}


sub get_my_gateway {
    my $prev_path = $ENV{"PATH"};
    $ENV{"PATH"} = "/bin:/sbin:/usr/bin:/usr/sbin";
    my $netstat = `netstat -nr`;
    $ENV{"PATH"} = $prev_path;
    my @netstat = split( /\n/, $netstat );

    foreach (@netstat) {
     if (/^0.0.0.0\s+(\S+)/) {
      return $1;
     }
    }
    return undef;
}



sub get_my_ip_10 {
  my $x = get_my_ip();
  $x =~ s/^\d+/10/ if (defined $x);
  return $x;
}

sub expand_vars {
    my $content = shift;
    my $hostname = get_hostname();
    my $boothost = get_boothost();
    my $adminhost = get_adminhost();
    my ($shortname) = split(/\./,$hostname,2);
    my ($shortboothost) = split(/\./,$boothost,2);
    my ($shortadminhost) = split(/\./,$adminhost,2);
    my ($ip) = get_my_ip();
    my ($ip10) = get_my_ip_10();
    my ($gateway) = get_my_gateway();
    my $gateway2 = $gateway;
    if ($gateway =~ m/[13579]$/) {  
      # Odd.  Add one.
      $gateway2 =~ s#(\d+)$#$1+1#e;
    } else {
      $gateway2 =~ s#(\d+)$#$1-1#e;
    }
    
    for ($content) {
	s/::hostname::/$hostname/g;
        s/::shortname::/$shortname/g;
        s/::shorthostname::/$shortname/g;
        s/::boothost::/$boothost/g;
        s/::shortboothost::/$shortboothost/g;
        s/::adminhost::/$adminhost/g;
        s/::shortadminhost::/$shortadminhost/g;
        s/::ip::/$ip/g;
        s/::ip10::/$ip10/g;
        s/::ipgw::/$gateway/g;
        s/::ipgw2::/$gateway2/g;
        s/::gw::/$gateway/g;
        s/::gw2::/$gateway2/g;
    }

    return $content;
}

=item motd($header,$content [,header,content..])

Read in /etc/motd, update or add a line starting wiht ^$header:

=cut
sub motd {
    my (@stuff) = @_;
    my $motd = read_file("/etc/motd");
    my @motd = split(/\n/,$motd);
    while(scalar(@stuff)) {
       my $header = shift @stuff;
       my $content = shift @stuff;
       $header =~ s/\s*:*\s*$//;  # Clean up trailing stuff
       $content =~ s/\s+$//;      # Clean trailing spaces and newlines
       $content =~ s/[\r\n]//g; # Remove linebreaks
       @motd = grep(!/^${header}\s*:/i,@motd);
       if (defined $content) { 
          push(@motd,"${header}: $content");
       }
    }
    $motd = join("\n",@motd,"");
    write_file("/etc/motd", $motd);
}



1;
