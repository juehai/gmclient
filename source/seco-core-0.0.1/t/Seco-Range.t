use Test::More tests => 2;
BEGIN { use_ok('Seco::Range') };

my @r = Seco::Range::expand_range('foo1-foo5');
ok(scalar @r == 5, 'foo1-foo5');

