use strict;
use Test;

BEGIN {
    plan tests => 28;
}
END { print "not ok 1\n" unless $main::loaded; }

use NHGRI::Db::Connector;
ok $main::loaded = 1;

if (!-f 'test') {
    skip("skip no test realm",0) for (1..10);
    exit 0;
}

my ($dbc, $dbh);
eval {
    $dbc = new NHGRI::Db::Connector(-connection_dir => '.', -realm => 'test');
    $dbh = $dbc->connect;
};
if ($@){
    warn $@;
}
ok($dbh && !$@);  # normal connection

# Test that warns on extra parameters
$SIG{__WARN__} = sub { die @_ };
eval {
    $dbc = new NHGRI::Db::Connector(-connection_dir => '.', -realm => 'test',
            -extra => 'ignored');
};
ok $@, qr/EXTRA => 'ignored'/, "warn about extra parameter";

# But should still work
$SIG{__WARN__} = sub {};
$dbc = undef;
eval {
    $dbc = new NHGRI::Db::Connector(-connection_dir => '.', -realm => 'test',
            -extra => 'ignored');
};
ok $@, "", "extra params not fatal";
$dbh = $dbc->connect();
ok $dbh->{Active};

# should automatically disconnect
undef $dbc;
ok !$dbh->{Active};

# should not disconnect
$dbc = new NHGRI::Db::Connector(-connection_dir => '.', -realm => 'test',
            -no_disconnect => 1);
ok $dbc;
$dbh = $dbc->connect();
ok $dbh->{Active};
undef $dbc;
ok $dbh->{Active};
$dbh->disconnect();

$dbc = new NHGRI::Db::Connector(-connection_dir => '.', -realm => 'test');
$dbh = $dbc->connect();
my $dbc2 = $dbc->clone();
my $dbh2 = $dbc2->connect();
ok $dbh2 ne $dbh;
undef $dbc;
ok $dbh2->{Active};

# What happens when lose connection?
$dbh2->disconnect();
ok !$dbh2->ping();
$dbh=$dbc2->connect();
ok $dbh->{Active}, 1, 'should automatically reconnect';
ok $dbh->ping();

# Test time suffixes
my $sec = NHGRI::Db::Connector::_time_to_sec('23 sec');
ok $sec, 23, "seconds";
$sec = NHGRI::Db::Connector::_time_to_sec('2.5m');
ok $sec, 2.5*60, "minutes";
$sec = NHGRI::Db::Connector::_time_to_sec(' .1h ');
ok $sec, .1*60*60, "hours";
$sec = NHGRI::Db::Connector::_time_to_sec('5days');
ok $sec, 5*60*60*24, "days";
eval {
    $sec = NHGRI::Db::Connector::_time_to_sec('2 weeks');
};
ok $@=~/not understood/;

# Test intervals

my $int = 0;
for my $exp (1, 2, 4, 8, 16, 32, 60, 60) {
    $int = $dbc2->_next_interval($int, 60);
    ok $int, $exp, 'next interval';
}
$dbc = NHGRI::Db::Connector->new(
        connection_dir => '.', 
        realm => 'test',
        min_interval    => 5,
        max_interval    => '10m',
        max_wait        => '3h',
        );
my @expected;
$int = 5;
my $tot = 0;
while ($tot + $int < 3*60*60) {
    push @expected, $int;
    $tot += $int;
    $int = $int + $int;
    $int = 600 if $int > 600;
}
my @observed;
$int = 0;
$tot = 0;
while (1) {
    $tot += $int;
    $int = $dbc->_next_interval($int);
    last if $tot + $int > 3*60*60;
    push @observed, $int;
}
ok scalar(@observed), scalar(@expected), "number of intervals same";
print "Obs: @observed\n";
print "ObsSum: ", sum(@observed);
print "Exp: @expected\n";
print "ExpSum: ", sum(@expected), " max: ", 3*60*60, "\n";

sub sum {
    my $sum = shift;
    for (@_) {
        $sum += $_;
    }
    return $sum;
}
