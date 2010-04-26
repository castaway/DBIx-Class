package # hide from PAUSE
  DBICTest::Schema::NoBackRels;

use strict;
use warnings;

use base qw/DBICTest::BaseResult/;

__PACKAGE__->table('cd');

__PACKAGE__->add_columns(
  'cdid' => {
    data_type => 'integer',
    is_auto_increment => 1,
  },
  'artist' => {
    data_type => 'integer',
  },
  'title' => {
    data_type => 'varchar',
    size      => 100,
  },
  'year' => {
    data_type => 'varchar',
    size      => 100,
  },
  'genreid' => { 
    data_type => 'integer',
    is_nullable => 1,
    accessor => undef,
  },
  'single_track' => {
    data_type => 'integer',
    is_nullable => 1,
    is_foreign_key => 1,
  }
);
__PACKAGE__->set_primary_key('cdid');
__PACKAGE__->add_unique_constraint([ qw/artist title/ ]);

__PACKAGE__->belongs_to( artist => 'DBICTest::Schema::Artist');
__PACKAGE__->has_many( tracks => 'DBICTest::Schema::Track', 'cd' );

1;
