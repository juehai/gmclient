package Seco::RunAs;

use warnings;
use strict;
use POSIX qw();
use Exporter qw(import);
our @EXPORT = qw( run as );

sub run(&@) {
    my ($block, $user, $group) = @_;
    die "Only root can RunAs" if $>;
    local $) = local $( = POSIX::getgrnam($group) if $group;
    local $> = local $< = POSIX::getpwnam($user) if $user;
    return $block->();
}

sub as {
    unless (@_) { warn "run as invoked with no user"; return }
    return $_[0] if 1 == @_;
    return $_[1] if 2 == @_ and $_[0] eq 'user';
    return @_ if 2 == @_;
    return $_[1], $_[3] if 4 == @_;
    die "Bad params to run/as: need 1,2 or 4 args";
}

1;

__END__

=pod

=head1 NAME

  Seco::RunAs - syntax extension to easily run code blocks with a
  different euid. You'll probably need to be root to begin with.

=head1 SYNOPSIS

  use Seco::RunAs;
  run { print `id` } as "nobody";

=head1 DESCRIPTION

B<Seco::RunAs> lets you run certain blocks of code with a non-root effective
user id with an easily read syntax.

=head1 METHODS

=item run { block } "user"

C<run> takes a block or coderef, and runs it as the given user.

=item as "user"

C<as> simply returns its first argument; it just looks nice.

=head1 EXAMPLES

=head2 Set user and group

  run { print `id` } as "nobody", "nogroup";

=head2 Set user with named args

  run { print `id` } as user => "nobody";

=head2 Set user, group with named args

  run { print `id` } as user => "nobody", group => "nobody;

=head1 AUTHOR


=cut

