use strict;
use Sys::Hostname;

package Seco::MultiPhasic;

sub new {
    my $class = shift;
    my %args  = @_;
    
    my $self = { };

    # Either a range of or a list of hosts is needed

    die "Range or a lists of hosts not provided"
      unless defined $args{'hosts'}
        or defined $args{'range'};

    $self->{_source} = Sys::Hostname->hostname;

    bless( $self, $class );

    # Convert either a range of hosts, or a list of hosts into an array of hosts, then
    # do a quick scan (using a user-defined filter) for the hosts that are up

    if ( defined $args{'range'} ) {
    }
    else {
        $self->{_hosts} = [ grep { $self->is_up($_) }  split /\,/, $args{'hosts'} ];
    }

    return $self;
}

# Placeholder: a procedure to check if the host is up or not

sub is_up {
    my $self = shift;
    my $target = shift;

    return 1;
}

# Invoke this to begin running

sub go {
    my $self = shift;
    
    $self->{_sources} = [ $self->{_source} ];
    $self->{_destinations} = $self->{_hosts};
    $self->{_failures} = { };
    $self->{_busy} = { };

    while (@{$self->{_destinations}}) {
        my @old_sources = @{$self->{_sources}};

        for my $source ( @old_sources ) { 
            my $dest = shift @{$self->{_destinations}} or last;

            # Give up after three tries
            if ($self->{_failures}->{$source} > 3) {
                @{$self->{_sources}} = grep { $_ != $source } @{$self->{_sources}};
                unshift @{$self->{_destinations}}, $dest;
            } 
            else {
                if (! $self->wrapper(from => $source, to => $dest) ) {
                    $self->{_failures}->{$source}++;
                    unshift @{$self->{_destinations}}, $dest;
                }
                else {
                    unshift @{$self->{_sources}}, $dest;    
                }
            }
        }
    }
}


sub set_busy {
    my $self = shift;
    my $hst = shift;

    while ($self->{_busy}->{$hst}) { }
    $self->{_busy}->{$hst} = 1;
}

sub set_unbusy {
    my $self = shift;
    my $hst = shift;

    $self->{_busy}->{$hst} = 0;
}

sub wrapper {
    my $self = shift;
    my %args = @_;

    print "From:  $args{from}   to  $args{to}\n";
    my $rv = $self->handler(%args);
   
    return $rv;
}

sub handler {
    my $self = shift;
    my %args = @_;
    
    my $src = $args{from};
    my $dst = $args{to};
    
    $self->set_busy($src);
    $self->set_busy($dst);
    
    # Do the forking/etc.. here
    
    $self->set_unbusy($src);
    $self->set_unbusy($dst);
    
    return 1;
}

1;
