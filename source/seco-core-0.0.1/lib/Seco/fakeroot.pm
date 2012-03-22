package Seco::fakeroot;

use strict;
use Carp;
our ($VERSION);

$VERSION = '1.0.0';

use constant FAKEROOT => qw ( /usr/local/bin/fakeroot
			      /usr/bin/fakeroot );

sub import {
    return if $> == 0;

    my $whoami = getpwuid($>);
    warn "$whoami: This application needs to pretend it's root.\n" .
         "Invoking fakeroot.\n\n";

    foreach my $fakeroot (reverse FAKEROOT) {
	next unless -x $fakeroot;
	exec($fakeroot, $0, @main::ARGV) ||
	  croak "ERROR: exec returned: $!";
    }

    croak "ERROR: unable to find a suitable fakeroot binary";
}

1;

