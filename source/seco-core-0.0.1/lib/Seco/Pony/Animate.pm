package Seco::Pony::Animate;

use warnings;
use strict;
use Curses;
use Data::Dumper;

our %frames;
our %sequence;

sub new {
    my ($class, $arg) = @_;
    $arg = { pony => $arg } unless ref $arg eq 'HASH'; # call new("pony") or new({k => v})
    if ( $arg->{color} ) {
        $arg->{color} = "\e[31m" if $arg->{color} =~ /red/i;
        $arg->{color} = "\e[32m" if $arg->{color} =~ /green/i;
        $arg->{color} = "\e[35m" if $arg->{color} =~ /purple/i;
        $arg->{color} = "\e[34m" if $arg->{color} =~ /blue/i;
    }
    my @types;
    local $/="";
    {
        local $/="NEWPONY";
        @types = <DATA>;
        chomp @types;
    }
    shift @types; # toss starter;
# format is
# line 1: name of animation
# line 2: \s delim line showing frame sequence
# line 3+: pony frames

    foreach my $t (@types) {
        my @rf = split /^$/ms, $t;
        my @header = split(/\W+/s, shift @rf);
	shift @header;
	my $name = shift @header;
        $sequence{$name} = \@header;
        @rf = map { [ split "\n"] } @rf;
        $frames{$name} = \@rf;
    }
    $arg->{pony} ||= ${[keys %frames]}[rand keys %frames];
    initscr;
    return bless $arg, $class;
}

sub DESTROY {
    endwin;
}

sub animate {
    my ($self, $delay) = @_;
    $delay ||= 1;
    print $self->{color} if exists $self->{color};
    for my $i (@{ $sequence{ $self->{pony} } }) {
        blit(2, 1, @{$frames{$self->{pony}}->[$i]});
	select(undef, undef, undef, 0.25);
    }
}

# give $x:int, $y:int, @listoflines to blit
# x,y is upper right corner
sub blit {
    my ($x, $y, @l) = @_;
    for (my $i=0; $i<@l; $i++) {
        addstr($y + $i, $x, $l[$i]);
    }
    refresh;
}
1;

# Format of pony is a NEWOPONY line, followed
# by a line with a word naming the animation, then the frame sequence
# after that, blank line delimited animation frames until the next NEWPONY.

__DATA__
NEWPONY
head 0 0 0 1 1 0 0 0

                  ,
                 / \,,_  .'|
              ,{{| /}}}}/_.'
             }}}}` '{{'  '.
           {{{{{    _   ;, \
        ,}}}}}}    /o`\  ` ;)
       {{{{{{   /           (
       }}}}}}   |            \
      {{{{{{{{   \            \
      }}}}}}}}}   '.__      _  |
      {{{{{{{{       /`._  (_\ /
       }}}}}}'      |    \\___/
       `{{{{`       |     '--'
        }}}`

                  ,
                 / \,,_  .'|
              ,{{| /}}}}/_.'
             }}}}` '{{'  '.
           {{{{{    _   ;, \
        ,}}}}}}    /-`\  ` ;)
       {{{{{{   /           (
       }}}}}}   |            \
      {{{{{{{{   \            \
      }}}}}}}}}   '.__      _  |
      {{{{{{{{       /`._  (_\ /
       }}}}}}'      |    \\___/
       `{{{{`       |     '--'
        }}}`

NEWPONY
prance 0 1 0 1 0

                     ,
                    })`-=--.  
                   }/  ._.-'
          _.-=-...-'  /    
        {{|   ,       |
        {{\    |  \  /_
        }} \ ,'---'\___\
        {  )/\\     \\ >\
          //  >\     >\`- 
         `-   `-     `-

                     ,
                    })`-`--.  
                   }/  . --'
          _.-=-...-'  / \___
        {{|   ,       |
        {{\    |  \  /_
        }} \ ,\---'| |
         {  \\ >\  | |
            >\` -  |_>
             `-

