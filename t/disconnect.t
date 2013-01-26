use Test::More;
plan tests => 4;

use_ok 'DBIx::Connector';

my $is_oracle;
open REALM, "test"; # ignore error if missing
while (<REALM>) {
    if (/DBD\s*=\s*Oracle/) {
        $is_oracle = 1;
    }
}
SKIP: {
    skip "Test db is not transaction-capable", 3 if !$is_oracle;

{   # create a scope
    my $dbc = DBIx::Connector->new(
            realm => 'test',
            connection_dir => '.',
            dbi_attrib => {
                AutoCommit => 0,
                },
            );
    isa_ok $dbc, 'DBIx::Connector';

    my $dbh = $dbc->connect();
    $dbh->do(q{
            begin execute immediate 'drop table dbix_c_test';
                exception when others then null;
            end;
            });
    $dbh->do('CREATE TABLE dbix_c_test (id int)');
    $dbh->do('INSERT INTO dbix_c_test VALUES (42)');
    $dbh->commit();

    $dbh->do('INSERT INTO dbix_c_test VALUES (11)');
    $dbc->disconnect();

    $dbh = $dbc->connect();
    my $ra = $dbh->selectcol_arrayref('SELECT id from dbix_c_test');
    is_deeply $ra, [42], 'Only have committed changes after disconnect';

    $dbh->do('INSERT INTO dbix_c_test VALUES (13)');
}
# now $dbc is out of scope, should have disconnected

my $dbc = DBIx::Connector->new(
        realm => 'test',
        connection_dir => '.',
        dbi_attrib => {
            AutoCommit => 0,
            },
        );
my $dbh = $dbc->connect();
my $ra = $dbh->selectcol_arrayref('SELECT id from dbix_c_test');
is_deeply $ra, [42], 'Only have committed changes after destruction';

} # end SKIP
