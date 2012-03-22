package Seco::Proxy::TargetCluster;
use base qw(Seco::Accessor);
Seco::Proxy::TargetCluster->mk_accessors(name => '/dev/null',
                                         percent => 0,
                                         flags => '-markprimary ' .
                                         '-substclient proxy',
                                         database => 'www',
                                         port => 55555);

package Seco::Proxy::Tier;
use base qw(Seco::Accessor);
Seco::Proxy::Tier->mk_accessors(name => '');
Seco::Proxy::Tier->mk_array_accessors(clusters => [],
                                      flags => '');

sub dup { # dup clusters too
    my $tier = shift;
    my $newtier = $tier->new(%$tier);
    my @clusters;
    foreach my $cluster ($tier->clusters) {
        push @clusters, $cluster->dup;
    }
    $newtier->clusters(@clusters);
    return $newtier;
}

sub proxystring {
    my $self = shift;
    my %args = @_;
    
    my $string = '';
    foreach my $flag ($self->flags) {
        $string .= "$flag " unless $flag =~ /^-avelat/;
    }
    
    foreach my $cluster ($self->clusters) {
        $string .= " " . $cluster->flags . " { " . $cluster->percent . "%" .
          $cluster->database . " " . $cluster->name . " " .
            $cluster->port . " }";
    }
    
    return undef unless $string;
    my $loadsplit = '';
    $loadsplit = ' loadsplit' unless $args{full};
    
    return "proxy cluster " . $self->name . "$loadsplit $string\n";
}

sub maintstring {
    my $self = shift;
    my %args = @_;
    
    return undef unless defined($args{enable});
    my $truth = 0;
    $truth = 1 if($args{enable});
    
    return "proxy maint " . $self->name . " $truth\n";
}

sub stringify_self {
    my $self = shift;
    
    my %percents;
    
    foreach my $cluster ( sort { $a->name cmp $b->name } $self->clusters) {
        my $name = $cluster->name;
        $name =~ s/\.cluster\.inktomisearch\.com//;
        
        $percents{$name} ||= 0;
        $percents{$name} += $cluster->percent;
    }
    
    my @outs = ();
    foreach my $name ( sort keys %percents ) {
        next unless $percents{$name}; # zero? who cares
        push @outs, $percents{$name} . "% $name";
    }
    
    my $outstr = $self->name;
    $outstr .= ' ' x (20 - length($self->name)) if(length($self->name) < 20);
    $outstr .= ' -> ';
    $outstr .= join ', ', @outs;
    
    return $outstr;
}

sub bcp {
    my $self = shift;
    my %args = @_;
    my $highlow = $args{highlow};
    
    if(!defined($highlow)) {
        if($self->name =~ /_(low|high)$/) {
            $highlow = $1;
        } elsif($self->name =~ /_(\d)$/) { # i.e. es_1, es_2
            if($1 % 2) { # odd
                $highlow = 'high';
            } else {
                $highlow = 'low';
            }
        } else {
            warn "Unable to BCP: don't know if " . $self->name .
              " is low or high\n";
            return undef;
        }
    }
    
    my @clusters = $self->clusters;
    
    foreach my $cluster (@clusters) {
        $cluster->percent($cluster->percent / 2);
    }
    
    my $null = Seco::Proxy::TargetCluster->new(name => '/dev/null',
                                               percent => 50,
                                               database => '',
                                               port => 55555,
                                               flags => '');
    unshift @clusters, $null if($highlow eq 'low');
    push @clusters, $null if($highlow eq 'high');
    
    $self->clusters(@clusters);
    return $self;
}

sub normalize {
    my $self = shift;
    
    my $total = 0;
    foreach my $cluster ($self->clusters) {
        $total += $cluster->percent;
    }
    
    foreach my $cluster ($self->clusters) {
        $cluster->percent($cluster->percent * 100 / $total);
    }
}

package Seco::Proxy;
use base qw(Seco::Accessor);
use 5.006;
use strict;
use warnings 'all';
use Seco::Range qw(:common);
use Seco::MultipleTcp;
Seco::Proxy->mk_accessors(maxflight => 1,
                          dryrun => 0,
                          verbose => 0,
                          mark => undef,
                          bcp => 0,
                          sleep => 1,
                          shuffle => 0,
                          sock_timeout => 10,
                          database => 'www',
                          force => 0,
                          full => 0);
Seco::Proxy->mk_array_accessors(spectiers => []);

our $VERSION = '1.0.0';

sub new {
    my $class = shift;
    my %args = @_;
    
    my $self = bless { ($class->_defaults, %args) }, $class;
    
    return undef unless $self->{range};
    $self->range($self->{range});
    
    $self->read_configs;
    $self->parse_tiers;
    return $self;
}

sub range {
    my $self = shift;
    my $range = shift;
    
    $self->setnodes(expand_range($range));
}

sub node {
    my $self = shift;
    my $nodename = shift;
    return $self->{nodes}->{$nodename};
}

sub setnodes {
    my $self = shift;
    my @nodelist = @_;
    
    my %nodes = ();
    foreach my $nodename (@nodelist) {
        $nodes{$nodename} = Seco::Proxy::Node->new(name => $nodename);
    }
    $self->{nodes} = \%nodes;
}

sub nodes {
    my $self = shift;
    return values %{$self->{nodes}};
}

sub dumpconfig {
    my $self = shift;
    my $str = "";
    
    foreach my $node ($self->nodes) {
        foreach my $line ($node->config) {
            $str .= $node->name . ": $line\n";
        }
    }
    return $str;
}

sub who_uses {
    my $self = shift;
    my %search = map { $_ => 1, "$_.cluster.inktomisearch.com" => 1 } @_;
    my %found;
    
    foreach my $node ($self->nodes) {
        my @list = ();
        my $found = 0;
        foreach my $tier ($node->eachtier) {
            foreach my $cluster ($tier->clusters) {
                next if $tier->name =~ /_center$/;
                next unless $cluster->percent;
                if($search{$cluster->name}) {
                    my $name = $cluster->name;
                    $name =~ s/\.cluster\.inktomisearch\.com$//;
                    push @list, $name;
                    $found = 1;
                }
                last if $found;
            }
            last if $found;
        }
        $found{$node->name} = \@list if(@list);
    }
    
    return \%found;
}

sub read_configs {
    my $self = shift;
    
    my $limit = "";
    # If we are told what clusters we are about, tell the proxy to
    # only tell us those clusters (and their _center equivalents)
    if(my @list = $self->spectiers) {
        push @list, map ( $_ . "_center", @list);
        my $loadsplit = '';
        $loadsplit = ' loadsplit' unless $self->full;
        $limit = "proxy cluster " . join(",",@list) . $loadsplit . "\n";
    }
    
    my $res =
      $self->broadcast(msg =>
                       "idp\nclient:inktomi\n\nPROXY\nproxy quiet\n$limit\n",
                       sleep => 0,
                       maxflight => 10);
    
    return undef unless $res;
    foreach my $node ($res->not_ok) {
        my $reason = (defined $node->error) ? $node->error : "";
        print STDERR $node->name . ": connect failure $reason\n";
    }
    
    foreach my $node ($res->ok) {
        my @list = split /\n/, $node->readbuf;
        $self->node($node->name)->config(@list);
    }
}

sub parse_tiers {
    my $self = shift;
    
    foreach my $node ($self->nodes) {
        $node->parse_tiers;
    }
}

sub load_diff {
    my $self = shift;
    
    my %diffs = ();
    
    foreach my $node ($self->nodes) {
        $diffs{$node->name} = $node->load_diff;
    }
    
    return \%diffs;
}

sub load_set_simple {
    my $self = shift;
    my %args = @_;
    
    my $tiername = $args{tiername};
    my $clusters = $args{clusters};
    my $database = defined($args{database}) ? $args{database} : $self->database;
    
    my @clusts = @$clusters;
    
    my %strings;
    
    # grab a default flags
    foreach my $node ($self->nodes) {
        my $oldtier = $node->{tiers}->{$tiername};
        unless (defined $oldtier) {
            warn "Could not find config for '$tiername' on " . $node->name;
            next;
        }
        
        # grab some default flags
        my $flags = '';
        my @c = $oldtier->clusters;
        $flags = $c[0]->flags;
        
        my @clusters = ();
        my $tier = $oldtier->dup;
        
        my $percents = 0;
        my $nempty = 0;
        foreach my $field (@clusts) {
            my ($name, $percent, $database) = split /:/, $field;
            $percents += $percent if defined($percent);
            $nempty++ unless defined($percent);
        }
        
        foreach my $field (@clusts) {
            my ($name, $percent, $database) = split /:/, $field;
            defined($database) or $database = $self->database;
            
            $name = "$name.cluster.inktomisearch.com"
              if($name ne '/dev/null' and $name ne 'localhost' and
                 $name !~ /\./ );
            $percent = ((100 - $percents) / $nempty) unless $percent;
            
            push @clusters,
              Seco::Proxy::TargetCluster->new(name => $name,
                                              percent => $percent,
                                              database => $database,
                                              port => 55555,
                                              flags => $flags);
        }
        
        $tier->clusters(@clusters);
        $tier->bcp if $self->bcp;
        $tier->normalize;
        my $string = $tier->proxystring(full => $self->full);
        $strings{$node->name} = $string if $string;
    }
    
    $self->broadcast_idp(msg => '',
                         override => \%strings);
}

sub noop {
    my $self = shift;
    $self->broadcast_idp();
}

sub load_set {
    my $self = shift;
    my $tier = shift;
    
    my %strings;
    
    $tier->bcp if $self->{bcp};
    $tier->normalize;
    
    foreach my $node ($self->nodes) {
        my $string = $tier->proxystring(full => $self->full);
        $strings{$node->name} = $string if $string;
    }
    
    $self->broadcast_idp(override => \%strings);
}

sub load_center {
    my $self = shift;
    my @tiers = @_;
    
    my %strings;
    
    foreach my $node ($self->nodes) {
        my $tmpstr = '';
        foreach my $tiername (@tiers) {
            next unless $node->{tiers}->{"${tiername}_center"};
            my $center = $node->{tiers}->{"${tiername}_center"}->dup;
            $center->name($tiername);
            $center->bcp if $self->bcp;
            my $string = $center->proxystring(full => $self->full);
            $tmpstr .= $string if $string;
            $string = $center->maintstring(enable => 0);
            $tmpstr .= $string if $string;
        }
        $strings{$node->name} = $tmpstr if $tmpstr;
    }
    
    $self->broadcast_idp(override => \%strings);
}

sub load_off {
    my $self = shift;
    my %args = @_;
    
    my %clusters = map { $_ => 1 } @{$args{clusters}};
    my @tiers = @{$args{tiers}};
    my $from_center = $args{from_center};
   
    $self->load_center(@{$args{tiers}})
      if($args{tiers} and $from_center);
 
    @tiers = keys %{$self->{tiers}} unless scalar @tiers;
    
    my %strings;
    foreach my $node ($self->nodes) {
        my $loadstring = '';
        
        foreach my $tiername (@tiers) {
            my $tier;
            if($from_center) {
                $tier = $node->{tiers}->{"${tiername}_center"};
            } else {
                $tier = $node->{tiers}->{$tiername};
            }
            
            next unless $tier;
            $tier = $tier->dup;
            $tier->name($tiername);
            
            my $survivor = undef;
            my $deadtotal = 0;
            my $livetotal = 0;
            
            my %deadclusters = ();
            my %liveclusters = ();
            
            foreach my $cluster ($tier->clusters) {
                my $stripped_name = $cluster->name;
                $stripped_name =~ s/\.cluster\.inktomisearch\.com$//;
                if($clusters{$cluster->name} or
                   $clusters{$stripped_name}) {
                    $deadclusters{$cluster->name} = $cluster;
                    $deadtotal += $cluster->percent;
                } else {
                    $liveclusters{$cluster->name} = $cluster;
                    $livetotal += $cluster->percent;
                    $survivor = $cluster->name; # lucky you, you get extra load
                }
            }
            
            next unless (scalar keys %deadclusters > 0);
            
            my @newclusters = ();
            if(!defined($survivor)) { # no one left to shoulder the load
                warn "This leaves $node->{name}:$tier->{name} with no " .
                  "cluster to send load to.\n";
                die "Quitting: Null load, no --force\n" unless $self->force;
                warn "Continuing anyway per --force...\n";
                push @newclusters,
                  Seco::Proxy::TargetCluster->new(name => '/dev/null',
                                                  percent => 100,
                                                  database => $self->database,
                                                  port => '55555',
                                                  flags => '-markprimary ' .
                                                  '-substclient proxy');
            } else { # distribute the load amongst remaining clusters
                my %each;
                my $remaining = $deadtotal / (scalar keys %deadclusters);
                foreach my $cluster (values %liveclusters) {
                    my $value = sprintf("%.3f", $cluster->percent / $livetotal *
                                     $deadtotal / (scalar keys %deadclusters) );
                    $each{$cluster->name} = $value;
                    $remaining -= $value;
                }
                
                $each{$survivor} += $remaining;
                
                foreach my $cluster ($tier->clusters) {
                    if($deadclusters{$cluster->name}) { # divvy it up
                        foreach my $key (sort keys %liveclusters) {
                            my $new = $liveclusters{$key}->dup;
                            $new->percent($each{$new->name});
                            push @newclusters, $new;
                        }
                    } else {
                        push @newclusters, $cluster->dup
                          if($cluster->percent > 0);
                    }
                }
            }
            
            $tier->clusters(@newclusters);
            
            my $string = $tier->proxystring(full => $self->full);
            $loadstring .= $string if $string;
            $string = $tier->maintstring(enable => 1);
            $loadstring .= $string if $string;
        }
        $strings{$node->name} = $loadstring if $loadstring;
    }
    
    my $res = $self->broadcast_idp(override => \%strings);
}

sub broadcast_idp {
    my $self = shift;
    my %opts = @_;
    
    my $msg = $opts{msg} || '';
    my $override = $opts{override} || {};
    
    if($self->mark) {
        my $markline = "proxy cluster " . $self->mark .
          " { 100%www /dev/null 55555 }\n";
        $msg .= $markline;
        
        foreach my $key (keys %$override) {
            $override->{$key} .= $markline;
        }
    }
    
    if($self->dryrun) {
        my @nodes;
        if($opts{do_empty} or $msg ne '') {
            @nodes = keys %{$self->{nodes}};
        } else {
            @nodes = grep { $override->{$_} } keys %{$self->{nodes}};
        }
        
        if ($self->shuffle) {
            $_ = reverse $_ foreach (@nodes);
            @nodes = sort @nodes;
            $_ = reverse $_ foreach (@nodes);
        } else {
            @nodes = sort @nodes;
        }
        
        foreach my $nodename (@nodes) {
            my $string = $override->{$nodename};
            print $nodename . ":\n" . $string . "\n";
        }
        
        return undef unless $msg;
        print "Default for " . $self->{range} . ":\n";
        print $msg;
        print "\n";
        
        return undef;
    }
    
    foreach my $key (keys %$override) {
        $override->{$key} = "idp\nclient:inktomi\n\nPROXY\nproxy quiet\n" .
          $override->{$key} . "\n";
    }
    
    return $self->broadcast(%opts,
                            msg =>
                            "idp\nclient:inktomi\n\nPROXY\nproxy quiet\n" .
                            $msg . "\n",
                            override => $override);
}

sub broadcast {
    my $self = shift;
    my %opts = @_;
    
    my $msg = $opts{msg} || '';
    my $override = $opts{override};
    my $do_empty = $opts{do_empty};
    my $sleep = (defined($opts{sleep}) ? $opts{sleep} : $self->sleep);
    my $maxflight = (defined($opts{maxflight}) ?
                     $opts{maxflight} : $self->maxflight);
    my $port = $opts{port} || 55555;
    return () unless scalar keys %{$self->{nodes}};
    
    my $sock_timeout = defined($opts{sock_timeout}) ? $opts{sock_timeout} :
      $self->sock_timeout;

    my $conn = Seco::MultipleTcp->new;
    
    my @nodes;
    if($opts{do_empty} or $msg ne '') {
        @nodes = keys %{$self->{nodes}};
    } else {
        @nodes = grep { $override->{$_} } keys %{$self->{nodes}};
    }
    
    if ($self->shuffle) {
        $_ = reverse $_ foreach (@nodes);
        @nodes = sort @nodes;
        $_ = reverse $_ foreach (@nodes);
    } else {
        @nodes = sort @nodes;
    }
    
    $conn->nodes(@nodes);
    $conn->port($port);
    $conn->sock_timeout($sock_timeout);
    $conn->minimum_time($sleep);
    $conn->maxflight($maxflight);
    $conn->global_timeout(0);
    $conn->writebuf($msg);
    $conn->nodewritebuf($override);
    
    if ($self->verbose) {
        $conn->yield_sock_finish(sub {
                                     my($self,$node) = @_;
                                     print "PROGRESS: finished: $node\n";
                                 });
        $conn->yield_sock_timeout(sub {
                                      my($self,$node) = @_;
                                      print "PROGRESS: TIMEOUT: $node\n";
                                  });
        $conn->yield_sock_start(sub {
                                    my($self,$node) = @_;
                                    print "PROGRESS: start: $node\n";
                                });
    }
    
    my $res = $conn->run;
    return $res;
}

#############
package Seco::Proxy::Node;
use 5.006;
use strict;
use warnings 'all';
use IO::Socket;

use base qw(Seco::Accessor);
Seco::Proxy::Node->mk_accessors(name => '',
                                tiers => '');
Seco::Proxy::Node->mk_array_accessors(config => [],
                                      flags => []);

sub stringify_self {
    shift->name;
}

sub dumpconfig {
    my $self = shift;
    
    my $ret = "";
    foreach my $line ($self->config) {
        $ret .= "$line\n";
    }
    
    return $ret;
}

sub parse_tiers {
    my $self = shift;
    
    $self->tiers( { } );
    
    foreach my $line ($self->config) {
        $line =~ s/\s+/ /g;
        if($line =~ s/^proxy cluster (\S+)//) {
            my $tier = Seco::Proxy::Tier->new(name => $1);
            
            my @clusters = ();
            while($line =~ s#(-markprimary)? \s*
                             (-substclient \s+ \S+)? \s*
                             { \s+ ([\d\.]+)%(\w+)? \s+
                                   (\S+|/dev/null|localhost)
                               \s+ (\d+) \s+ }##x) {
                my ($flags, $percent, $db, $clustname, $port) =
                  (($1||'') . ' ' . ($2||''), $3 + 0, $4 || '', $5, $6);
                
                (defined($percent) and defined($clustname)) or return
                  $self->error("Parse error from " . $self->name . ": $line");
                
                my $done = 0;
                
                push @clusters,
                  Seco::Proxy::TargetCluster->new(name => $clustname,
                                                  percent => $percent,
                                                  database => $db,
                                                  port => $port,
                                                  flags => $flags)
                      unless $done;
            }
           # $tier->clusters(sort { $a->name cmp $b->name } @clusters);
            $tier->clusters(reverse @clusters);
            
            my @flags = ();
            while($line =~ s/-(\w+) (\S+)//) {
                my ($var, $val) = ($1, $2);
                push @flags, "-$var $val";
            }
            $tier->flags(@flags);
            $self->tiers->{$tier->name} = $tier;
        }
    }
}

sub eachtier {
    my $self = shift;
    return values %{$self->tiers};
}

sub load_diff {
    my $self = shift;
    
    my %diff;
    
    foreach my $tiername (keys %{$self->{tiers}}) {
        next if $tiername =~ /_center$/;
        my $tier = $self->{tiers}->{$tiername};
        my $center = $self->{tiers}->{$tiername . "_center"};
        
        next unless (defined($tier) and defined($center));
        
        if(!defined($center)) {
            $diff{$tier->name} = $tier;
            next;
        }
        
        my $cpy = $center->dup->name($tier->name);
        if("$tier" ne "$cpy") {
            $diff{$tier->name} = $tier;
            $diff{$center->name} = $center;
        }
    }
    
    return \%diff;
}

1;

__END__

=pod

=head1 NAME

  Seco::Proxy - module to perform proxy load shift operations

=head1 SYNOPSIS

  my $proxy =
    Seco::Proxy->new(range => "ks321000-20",
                     verbose => 1,
                     dryrun => 0,
                     mark => undef,  # create a dummy load group
                     force => 0,
                     spectiers => [ 'ks_low', 'ks_high' ],
                        # tiers to inspect on load
                     sock_timeout => 20,
                     initsleep => 10,  # init is during read phase
                     initflight => 10,
                     database => 'www',
                     sleep => 10, # minimum time for each node
                     maxflight => 10, # nodes to run at once
                     shuffle => 0, # pseudorandom
                     bcp => 0); # split high/low for bcp

  # print raw proxy output
  print $proxy->dumpconfig;

  # let's inspect the data
  foreach my $node ($proxy->nodes) {
    my $tiers = $node->tiers;
    foreach my $tiername (sort keys %$tiers) {
      my $tier = $tiers->{$tiername};
      print $node->name . ": $tier";
    }
  }

  # who might send load to ks323, anyway?
  my $found = $proxy->who_uses('ks323');
  foreach my $node (keys %$found) {
    print "$node: " . (join ',', @{$found->{$node}}) . "\n";
  }

  # let's start breaking stuff.
  $proxy->load_set_simple(tiername => 'ks_low',
                          database => 'www',
                          clusters => [ 'ks321:50', '/dev/null:50' ]);

  # from_center will base on the _center line, if from_center => 0 then
  # the new load configuration will be based on the current.
  $proxy->load_off(tiers => [ 'ks_low', 'ks_high' ],
                   clusters => 'ks321',
                   from_center => 1);

  # Maint's over, let's recenter these.
  $proxy->load_center('ks_low', 'ks_high');



=head1 DESCRIPTION

Seco::Proxy takes a (Seco::Range) range of nodes and a set of 'tiers' ('proxy cluster' line labels in load config).  On initialization it will connect to each node in the range (using the initsleep and initflight values to determine its strategy) and query for all lines matching the labels in 'spectiers'.

=head1 CLASSES

=head2 Seco::Proxy::TargetCluster

=over 4

=item B<new>

Takes the following values:

  name: cluster to send load to (e.g. 'ks321' or '/dev/null')
  percent: percent of load to send to cluster
  flags: tag cluster with these (e.g. '-substclient proxy')
  database: database to use (www)
  port: port to connect to cluster (55555)

=head2 Seco::Proxy::Tier

=item B<new>

Takes the following values:

  name: 'proxy cluster' label (e.g. 'ks_high')
  clusters: an array of B<Seco::Proxy::TargetCluster> s

=head2 Seco::Proxy

=item B<new>

Takes the following values:

  maxflight: how many nodes to run at once
  dryrun: if this is 1, just print steps taken
  verbose: print debugging output
  mark: if this is set, create a dummy 'proxy cluster'
        line with this name
  bcp: if this is set, split _high and _low load according to
       BCP practices
  sleep: minimum amount of time to take per node
  shuffle: should we pseudorandomize the list of nodes?
  sock_timeout: how long to wait before moving on
  database: default database to use when creating new load groups
  force: if we should perform potentially dangerous operations
         (nulling load etc)
  full: if we shold read/set more than just the load info from proxy
        clusters

=item B<load_set>

Takes a B<Seco::Proxy::Tier> object and uses it to set load on proxy bank.  Will apply bcp and normalize load as necessary.

=item B<load_set_simple>

Arguments: (tiername => 'ks_high',
            # a list of clusters and the relative weights to load them at
            clusters => [ 'ks321:1', 'ks322:1', 'ks322:2' ],
            database => 'www');

Interface to load_set that builds the appropriate B<Seco::Proxy::Tier> object for you.

=item B<load_center>

Takes a list of 'proxy cluster' labels and applies settings found in the corresponding _center lines.

=item B<load_off>

Arguments:  (clusters => [ 'cluster1', 'cluster2' ],
             tiers => [ 'ks_low' ],
             from_center => (0|1))

Takes load off of all clusters given in all tiers given and rebalances.  If from_center is set, the _center line is used to base calculation on.



