#!/usr/bin/perl -w


use Getopt::Std;                                # for getopts()
use strict;                                     # prevent typos
use FindBin '$Bin';                             # locate libraries
#BEGIN { unshift(@INC,"$Bin/../lib") }
#use lib "/home/admin/tools/lib";
use Seco::FnSeco;

my( $line, %range, $entry, @entries);
use vars '$opt_h';
use vars '$opt_c';
use vars '$opt_L';

#############################################################################
# Check for -h
#############################################################################
if( !(getopts("hLc:")) || $opt_h)
{
        print "Usage:\tmklist[-h] [-L]\n";
        print "\treads data from STDIN and compresses the range\n";
        print "\t-L specifies CompressRangeBetter(); will output a QOUTED range\n";
        exit;
}

#############################################################################
# Main Code
#############################################################################
while( defined($line = <>))
{
        chomp($line);
	next if($line=~m/^\s*$/g);
        if (defined  $opt_c) {
                $line = (split(/\s+/,$line))[$opt_c - 1] ;
        }
        @entries = split( /[,\s+]/, $line);
        foreach $entry (@entries)
        {
                $range{$entry} = 1;
        }
}

### Check that we actaully got data
exit unless @entries;

if ($opt_L) {
  $line = &CompressRangeBetter( %range);
  $line = "\"$line\"";
} else {
  $line = &CompressRange( %range);
}

print $line, "\n";

