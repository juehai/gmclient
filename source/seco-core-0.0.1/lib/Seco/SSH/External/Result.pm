package Seco::SSH::External::Result;

=pod

=head1 NAME

Seco::SSH::External::Result - Returned by Seco::SSH::External

=head1 SYNOPSYS

  $result->ok;
  die if $result->exception;
  print $result->stderr;

=head1 DESCRIPTION

B<Seco::SSH::External::Result> provides a handy set of accessors to
read the results of a Seco::SSH::External command.

=cut

=item new()

Called by Seco::SSH::External.

=cut

sub new {
    my ($class, @init) = @_;
    if (ref $init[0] eq 'HASH') {
        return my $self = bless $init[0], $class;
    } else {
        return my $self = bless { @init }, $class;
    }
}

=item ok()

Ok returns true if $? was zero, we didn't exceed timeout,
and no exceptions were raised. Data on stderr is ok.

=cut

sub ok {
    my ($self) = @_;
    return 0 if $self->exception;
    return 0 if $self->{-timeout};
    return 0 unless defined $self->{-retval}; # undef if we didn't wait on it
    return 0 if $self->{-retval};
    return 1;
}

=item strictok()

Strictok returns true if the result was ok() and in addition had no
output on stderr.

=cut

sub strictok {
    my ($self) = @_;
    return 0 unless $self->ok;
    return 0 if length $self->stderr;
    return 1;
}

=item stdout()

Contains what, if anything, the command produced on stdout

=cut

sub stdout {
    my ($self) = @_;
    return $self->{-stdout};
}

=item stderr()

Contains what, if anything, the command produced on stderr

=cut

sub stderr {
    my ($self) = @_;
    return $self->{-stderr};
}

=item pid()

Contains pid of the spawned ssh process. You probably don't need this.

=cut

sub pid {
    my ($self) = @_;
    return $self->{-pid};
}

=item exception()

True if an exception took place while processing this.

=cut

sub exception {
    my ($self) = @_;
    return 1 if $self->{-rexception};
    return 1 if $self->{-wexception};
    return 1 if $self->{-gexception};
    return 0;
}

=item timedout()

True if we timed out

=cut

sub timedout {
    my ($self) = @_;
    return 1 if $self->{-timedout};
    return 0;
}

1;
