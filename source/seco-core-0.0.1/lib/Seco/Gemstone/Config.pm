package Seco::Gemstone::Config;

use Exporter;
use strict;
use FindBin qw/$Bin/;
use Sys::Hostname;
use Seco::Gemstone::Logger qw(log);


our @ISA = qw/Exporter/;
our @EXPORT_OK = qw/get_adminhost get_type get_telldserver get_multicast_dir/;

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

use Seco::Range qw/:common/;

{   

    # Change the following options to 
    # first do  $Findbin/../lib if does not exist  then /usr/local/lib/perl5/site_perl/Seco/Gemstone/
    my $config = do "config.pl";

    # no need to modify anything below this line
    sub get_adminhost {
        my $_ah;
        eval {  
                ($_ah) = expand_range('^' . hostname());
        };
        return $_ah if $_ah; # added by ting . avoid use /etc/hosts
        return $config->{adminhost};
    }
   
 
    sub get_type {
        return $config->{type};
    }

    sub get_telldserver {
        return $config->{telldserver};
    }

    sub get_multicast_dir {
        return $config->{multicastdir};
    }
}

1;


