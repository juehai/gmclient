package Seco::Accessor;
use strict;

use base qw(Class::Accessor);
use overload '""' => sub { shift->stringify_self; };

sub stringify_self {
    my $self = shift;
    my $string = "No stringification available.";
    
    eval {
        require Data::Dumper;
        $string = Data::Dumper::Dumper($self);
    };
    
    return $string;
}

sub new {
    my $proto = shift;
    my %rest;
    if(@_ == 0) {
        %rest =  ();
    } elsif(@_ == 1) {
        %rest = %{$_[0]} if (ref $_[0] eq 'HASH');
    } else {
        %rest = @_;
    }

    my $class = ref $proto || $proto;
    my %d = $class->_defaults;
    my $nd = $class->_dereference(\%d);

    my $self = bless { (%$nd, %rest) }, $class;

    return $self;
}

sub dup {
    my $self = shift;
    my %override = @_;
    $self->new(%$self, %override);
}

sub _dereference {
    my $class = shift;
    my $arg = shift;
    my $ret;

    if(ref $arg eq 'ARRAY') {
        my @newarray = @$arg;
        $_ = $class->_dereference($_) for (@newarray);
        $ret = \@newarray;
    } elsif(ref $arg eq 'HASH') {
        my %newhash = %$arg;
        $newhash{$_} = $class->_dereference($newhash{$_}) for (keys %newhash);
        $ret = \%newhash;
    } elsif(ref $arg eq 'SCALAR') {
        my $newscalar = $arg;
        $ret = \$newscalar;
    } else {
        $ret = $arg;
    }
    
    return $ret;
}


sub my_defaults {
    my $class = shift;
    my %args = $class->_defaults;
    my %myargs;
    foreach my $arg (keys %args) {
        if(ref $args{$arg}) {
            if(ref $args{$arg} eq 'ARRAY') {
                my @newarray = @{$args{$arg}};
                $myargs{$arg} = \@newarray;
            } elsif(ref $args{$arg} eq 'HASH') {
                my %newhash = %{$args{$arg}};
                $myargs{$arg} = \%newhash;
            } elsif(ref $args{$arg} eq 'SCALAR') {
                my $newscalar = ${$args{$arg}};
                $myargs{$arg} = \$newscalar;
            } else {
                $myargs{$arg} = $args{$arg};
            }
        } else {
            $myargs{$arg} = $args{$arg};
        }
    }
    
    return %myargs;
}


sub error {
    my $self = shift;
    my $msg = "@_";
    
    if($msg) {
        $self->{_error} = $msg;
        return undef;
    }
    
    return $self->{_error};
}

sub _defaults {
    ();
}

{
    no strict 'refs';
    no warnings;
    
    
    sub _mk_accessors {
        my ($self, $maker, %fields) = @_;
        my $class = ref $self || $self;
        my %oldfields;
        
        foreach ($class, @{"$class\::ISA"}) {
            next unless defined(&{$_."\::_defaults"});
            %oldfields = ($_->_defaults, %oldfields);
        }

        *{$class."\::_defaults"} = sub { (%oldfields, %fields) };
        
        # So we don't have to do lots of lookups inside the loop.
        $maker = $self->can($maker) unless ref $maker;
        $maker = $self->can("make_accessor") unless ref $maker;
        
        foreach my $field (keys %fields) {
            if( $field eq 'DESTROY' ) {
                require Carp;
                &Carp::carp("Having a data accessor named DESTROY in ".
                            "'$class' is unwise.");
            }
            
            my $accessor = $self->$maker($field);
            my $alias = "_${field}_accessor";
            
            *{$class."\:\:$field"}  = $accessor
              unless defined &{$class."\:\:$field"};
            
            *{$class."\:\:$alias"}  = $accessor
              unless defined &{$class."\:\:$alias"};
        }
    }
}

sub mk_array_accessors {
    my ($self, @fields) = @_;
    $self->_mk_accessors('make_array_accessor', @fields);
}

sub make_array_accessor {
    my ($class, $field) = @_;
    
    return sub {
        my $self = shift;
        
        if(@_) {
            return $self->_set_array($field, @_);
        } else {
            return $self->_get_array($field);
        }
    };
}

sub make_accessor {
    my ($class, $field, $default) = @_;
    
    # Build a closure around $field.
    return sub {
        my $self = shift;
        
        if(@_) {
            return $self->set($field, @_);
        }
        else {
            return $self->get($field);
        }
    };
}

sub set {
    my($self, $key) = splice(@_, 0, 2);
    
    if(@_ == 1) {
        $self->{$key} = $_[0];
    }
    elsif(@_ > 1) {
        $self->{$key} = [@_];
    }
    else {
        require Carp;
        &Carp::confess("Wrong number of arguments received");
    }
    
    return $self;
}

sub _set_array {
    my $self = shift;
    my $key = shift;
    $self->{$key} = \@_;
    
    return $self;
}

sub _get_array {
    my $self = shift;
    
    if(@_ == 1) {
        if(ref $self->{$_[0]}) {
            if(wantarray) {
                return @{$self->{$_[0]}};
            } else {
                return scalar @{$self->{$_[0]}};
            }
        } else {
            if(wantarray) {
                return ();
            } else {
                return 0;
            }
        }
    } else {
        require Carp;
        &Carp::confess("Wrong number of arguments received.");
    }
}

1;

__END__

=pod

=head1 NAME

  Seco::Accessor - base class to create accessors and constructors

=head1 SYNOPSIS

  package MyModule;
  use base qw(Seco::Accessor);
  MyModule->mk_accessors(foo => 'default value for foo',
                         bar => 78);

  ... meanwhile ...
  
  my $mm = MyModule->new(foo => 'replace default value with this');
  print $mm->bar;
  $mm->list(5, 3, 'hello');
  my $count = $mm->list;
  my @list = $mm->list;

  my $duplicate = $mm->dup;
  my $otherdup = $mm->dup(bar => 2);

  print $otherdup;
 
=head1 DESCRIPTION

Base your classes on Seco::Accessor to enable them to define accessor methods that take default values.  Seco::Accessor also defines a constructor 'new' that will take values to override defaults with, and a 'dup' method that will create a new object using the target's values as defaults.  References will not be followed, so a Seco::Accessor::dup'd object may not necessarily be totally independent.

Seco::Accessor defines a subroutine '_default' which returns a hash indiacting the default values you have assigned for all accessor elements.

A subroutine "error" exists in Seco::Accessor.  When called with an argument, it sets $object->{_error} to the value of the argument and returns undef.  When called without an argument, it returns the value of $object->{_error}.  This allows one to:
  dostuff or return $self->error("Stuff failed.");


to return undef, and set _error, and then
  warn($obj->error) if(!$obj->stuff);

in your scripts.

In addition, it overloads the stringification operator "" to use YourClass::stringify_self($obj) for stringification.  By default, this will print a Data::Dumper dump of the object.  You can override this behavior by overloading the method "stringify_self".
  
Seco::Accessor is based on Class::Accessor and the various types of accessors available there are supported.

Class::Accessor 'getter' methods are modified in that they return the target object.
