package Seco::Pony::Say;

use Seco::Pony;
use Seco::Slogan;

sub slogan {
    my $pony = Seco::Pony->get_pony;
    my @words = split ' ', Seco::Slogan->random;
    
    $pony =~ s/( {4,32})$/cramwords(\@words, length $1)/meg;
    return $pony;
}

sub cramwords {
    my ($words, $spaces) = @_;
    return "" unless @$words;
    my $ret = "   ";
    while (@$words) {
        last if ((length $ret) + (length $words->[0]) + 5) > $spaces; # line full
        my $word = shift @$words;
        $ret .= " $word";
    }
    return $ret;
}

1;
