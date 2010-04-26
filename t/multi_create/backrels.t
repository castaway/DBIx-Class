use strict;
use warnings;

use Test::More;
use Test::Exception;
use lib qw(t/lib);
use DBICTest;

my $schema = DBICTest->init_schema();

my $cd = $schema->resultset('NoBackRels')->create({
    artist => {
        name => 'Elvis',
    },
    title => 'Greatest Elvis hits',
    year => 1973,
    tracks => [
        { 
            title => 'Heartbreak hotel',
        },
        ],
});

isa_ok($cd, 'DBICTest::CD', 'Main CD object created');

done_testing;
