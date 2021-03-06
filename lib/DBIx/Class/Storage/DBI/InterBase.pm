package DBIx::Class::Storage::DBI::InterBase;

use strict;
use warnings;
use base qw/DBIx::Class::Storage::DBI/;
use mro 'c3';
use List::Util 'first';
use Try::Tiny;
use namespace::clean;

=head1 NAME

DBIx::Class::Storage::DBI::InterBase - Driver for the Firebird RDBMS

=head1 DESCRIPTION

This class implements autoincrements for Firebird using C<RETURNING> as well as
L<auto_nextval|DBIx::Class::ResultSource/auto_nextval> sets the limit dialect to
C<FIRST X SKIP X> and provides L<DBIx::Class::InflateColumn::DateTime> support.

You need to use either the
L<disable_sth_caching|DBIx::Class::Storage::DBI/disable_sth_caching> option or
L</connect_call_use_softcommit> (see L</CAVEATS>) for your code to function
correctly with this driver. Otherwise you will likely get bizarre error messages
such as C<no statement executing>. The alternative is to use the
L<ODBC|DBIx::Class::Storage::DBI::ODBC::Firebird> driver, which is more suitable
for long running processes such as under L<Catalyst>.

To turn on L<DBIx::Class::InflateColumn::DateTime> support, see
L</connect_call_datetime_setup>.

=cut

# set default
__PACKAGE__->_use_insert_returning (1);

sub _sequence_fetch {
  my ($self, $nextval, $sequence) = @_;

  if ($nextval ne 'nextval') {
    $self->throw_exception("Can only fetch 'nextval' for a sequence");
  }

  $self->throw_exception('No sequence to fetch') unless $sequence;

  my ($val) = $self->_get_dbh->selectrow_array(
'SELECT GEN_ID(' . $self->sql_maker->_quote($sequence) .
', 1) FROM rdb$database');

  return $val;
}

sub _dbh_get_autoinc_seq {
  my ($self, $dbh, $source, $col) = @_;

  my $table_name = $source->from;
  $table_name    = $$table_name if ref $table_name;
  $table_name    = $self->sql_maker->quote_char ? $table_name : uc($table_name);

  local $dbh->{LongReadLen} = 100000;
  local $dbh->{LongTruncOk} = 1;

  my $sth = $dbh->prepare(<<'EOF');
SELECT t.rdb$trigger_source
FROM rdb$triggers t
WHERE t.rdb$relation_name = ?
AND t.rdb$system_flag = 0 -- user defined
AND t.rdb$trigger_type = 1 -- BEFORE INSERT
EOF
  $sth->execute($table_name);

  while (my ($trigger) = $sth->fetchrow_array) {
    my @trig_cols = map {
      /^"([^"]+)/ ? $1 : uc($1)
    } $trigger =~ /new\.("?\w+"?)/ig;

    my ($quoted, $generator) = $trigger =~
/(?:gen_id\s* \( \s* |next \s* value \s* for \s*)(")?(\w+)/ix;

    if ($generator) {
      $generator = uc $generator unless $quoted;

      return $generator
        if first {
          $self->sql_maker->quote_char ? ($_ eq $col) : (uc($_) eq uc($col))
        } @trig_cols;
    }
  }

  return undef;
}

# this sub stolen from DB2

sub _sql_maker_opts {
  my ( $self, $opts ) = @_;

  if ( $opts ) {
    $self->{_sql_maker_opts} = { %$opts };
  }

  return { limit_dialect => 'FirstSkip', %{$self->{_sql_maker_opts}||{}} };
}

sub _svp_begin {
    my ($self, $name) = @_;

    $self->_get_dbh->do("SAVEPOINT $name");
}

sub _svp_release {
    my ($self, $name) = @_;

    $self->_get_dbh->do("RELEASE SAVEPOINT $name");
}

sub _svp_rollback {
    my ($self, $name) = @_;

    $self->_get_dbh->do("ROLLBACK TO SAVEPOINT $name")
}

sub _ping {
  my $self = shift;

  my $dbh = $self->_dbh or return 0;

  local $dbh->{RaiseError} = 1;
  local $dbh->{PrintError} = 0;

  return try {
    $dbh->do('select 1 from rdb$database');
    1;
  } catch {
    0;
  };
}

# We want dialect 3 for new features and quoting to work, DBD::InterBase uses
# dialect 1 (interbase compat) by default.
sub _init {
  my $self = shift;
  $self->_set_sql_dialect(3);
}

sub _set_sql_dialect {
  my $self = shift;
  my $val  = shift || 3;

  my $dsn = $self->_dbi_connect_info->[0];

  return if ref($dsn) eq 'CODE';

  if ($dsn !~ /ib_dialect=/) {
    $self->_dbi_connect_info->[0] = "$dsn;ib_dialect=$val";
    my $connected = defined $self->_dbh;
    $self->disconnect;
    $self->ensure_connected if $connected;
  }
}

sub _get_server_version {
  my $self = shift;

  return $self->next::method(@_) if ref $self ne __PACKAGE__;

  local $SIG{__WARN__} = sub {}; # silence warning due to bug in DBD::InterBase

  return $self->next::method(@_);
}

=head2 connect_call_use_softcommit

Used as:

  on_connect_call => 'use_softcommit'

In L<connect_info|DBIx::Class::Storage::DBI/connect_info> to set the
L<DBD::InterBase> C<ib_softcommit> option.

You need either this option or C<< disable_sth_caching => 1 >> for
L<DBIx::Class> code to function correctly (otherwise you may get C<no statement
executing> errors.) Or use the L<ODBC|DBIx::Class::Storage::DBI::ODBC::Firebird>
driver.

The downside of using this option is that your process will B<NOT> see UPDATEs,
INSERTs and DELETEs from other processes for already open statements.

=cut

sub connect_call_use_softcommit {
  my $self = shift;

  $self->_dbh->{ib_softcommit} = 1;
}

=head2 connect_call_datetime_setup

Used as:

  on_connect_call => 'datetime_setup'

In L<connect_info|DBIx::Class::Storage::DBI/connect_info> to set the date and
timestamp formats using:

  $dbh->{ib_time_all} = 'ISO';

See L<DBD::InterBase> for more details.

The C<TIMESTAMP> data type supports up to 4 digits after the decimal point for
second precision. The full precision is used.

The C<DATE> data type stores the date portion only, and it B<MUST> be declared
with:

  data_type => 'date'

in your Result class.

Timestamp columns can be declared with either C<datetime> or C<timestamp>.

You will need the L<DateTime::Format::Strptime> module for inflation to work.

For L<DBIx::Class::Storage::DBI::ODBC::Firebird>, this is a noop and sub-second
precision is not currently available.

=cut

sub connect_call_datetime_setup {
  my $self = shift;

  $self->_get_dbh->{ib_time_all} = 'ISO';
}

sub datetime_parser_type {
  'DBIx::Class::Storage::DBI::InterBase::DateTime::Format'
}

package # hide from PAUSE
  DBIx::Class::Storage::DBI::InterBase::DateTime::Format;

my $timestamp_format = '%Y-%m-%d %H:%M:%S.%4N'; # %F %T
my $date_format      = '%Y-%m-%d';

my ($timestamp_parser, $date_parser);

sub parse_datetime {
  shift;
  require DateTime::Format::Strptime;
  $timestamp_parser ||= DateTime::Format::Strptime->new(
    pattern  => $timestamp_format,
    on_error => 'croak',
  );
  return $timestamp_parser->parse_datetime(shift);
}

sub format_datetime {
  shift;
  require DateTime::Format::Strptime;
  $timestamp_parser ||= DateTime::Format::Strptime->new(
    pattern  => $timestamp_format,
    on_error => 'croak',
  );
  return $timestamp_parser->format_datetime(shift);
}

sub parse_date {
  shift;
  require DateTime::Format::Strptime;
  $date_parser ||= DateTime::Format::Strptime->new(
    pattern  => $date_format,
    on_error => 'croak',
  );
  return $date_parser->parse_datetime(shift);
}

sub format_date {
  shift;
  require DateTime::Format::Strptime;
  $date_parser ||= DateTime::Format::Strptime->new(
    pattern  => $date_format,
    on_error => 'croak',
  );
  return $date_parser->format_datetime(shift);
}

1;

=head1 CAVEATS

=over 4

=item *

with L</connect_call_use_softcommit>, you will not be able to see changes made
to data in other processes. If this is an issue, use
L<disable_sth_caching|DBIx::Class::Storage::DBI/disable_sth_caching> as a
workaround for the C<no statement executing> errors, this of course adversely
affects performance.

Alternately, use the L<ODBC|DBIx::Class::Storage::DBI::ODBC::Firebird> driver.

=item *

C<last_insert_id> support by default only works for Firebird versions 2 or
greater, L<auto_nextval|DBIx::Class::ResultSource/auto_nextval> however should
work with earlier versions.

=item *

Sub-second precision for TIMESTAMPs is not currently available when using the
L<ODBC|DBIx::Class::Storage::DBI::ODBC::Firebird> driver.

=back

=head1 AUTHOR

See L<DBIx::Class/AUTHOR> and L<DBIx::Class/CONTRIBUTORS>.

=head1 LICENSE

You may distribute this code under the same terms as Perl itself.

=cut
