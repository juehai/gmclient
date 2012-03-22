package Seco::sudo;

use strict;
use Carp;
our ($VERSION);

$VERSION = '1.0.0';

use constant SUDO => qw ( /usr/local/bin/sudo
			  /usr/bin/sudo );

sub import {
    shift;
    become($_[0]) if ($_[0]);
}

sub become {
    my $who = $_[0];
    my $uid = getpwnam($who);

    croak "must be passed a valid username"
      unless (($who) && (defined($uid)));

    return if $> == $uid;

    my $whoami = getpwuid($>);
    warn "$whoami: This application needs '$who' privileges.  Invoking sudo.\n";

    foreach my $sudo (reverse SUDO) {
	next unless -x $sudo;
	exec($sudo, '-u', $who, $0, @main::ARGV) ||
	  croak "ERROR: exec returned: $!";
    }

    croak "ERROR: unable to find a suitable sudo(1) binary";
}

__END__

=pod

=head1 NAME

Seco::sudo - change EUID/EGID of a script via re-exec'ing with sudo(8)

  # trickery to make the re-exec happen at compile-time
  # (this means if the sudo fails, so does compilation)
  use Seco::sudo qw /crawler/;

  # or alternatively at run-time
  use Seco::sudo;
  Seco::sudo::become('crawler');

=head1 AUTHOR

=head1 SEE ALSO

sudo(8), sudoers(5)

=cut
