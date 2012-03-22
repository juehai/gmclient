package Seco::MultipleSsh;

use strict;
use base qw(Seco::MultipleCmd);

__PACKAGE__->_accessors(connect_timeout => undef,
                        options => undef);

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);
    
    bless $self, $class;
    
    $self->{yield_modify_cmd} = sub
      {
          my $self = shift;
          my $node = shift;
          
          my @cmd = @{$self->cmd};
          my $repl = $self->replace_hostname;
          my $host = $node->hostname;
          my @out = map { s/$repl/$host/g; $_ } @cmd;
          
          unshift @out, $node->hostname;
          my $opts = '';
          
          if(defined($self->options)) {
              $opts = $self->options;
          }
          
          if(defined($self->connect_timeout)) {
              $opts .= "ConnectTimeout=" . $self->connect_timeout;
          }
          
          if($opts) {
              unshift @out, ('/usr/bin/ssh', '-o', $opts, '-q', '-x');
          } else {
              unshift @out, qw#/usr/bin/ssh -q -x #;
          }
          return @out;
      };
    
    return $self;
}

1;
