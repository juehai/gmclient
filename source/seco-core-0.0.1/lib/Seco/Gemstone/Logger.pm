package Seco::Gemstone::Logger;

use strict;
use Exporter;
use Carp;
use Sys::Syslog;

our @ISA = qw/Exporter/;
our @EXPORT_OK = qw/log/;

openlog("gemclient", "cons", "user");

sub log {
    my ($priority, $msg) = @_;
    syslog $priority, $msg;
    $priority = uc($priority);
    print "$priority: $msg\n";
}

1;
