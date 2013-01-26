#/usr/bin/perl -w
# $Id: dbc_passwd.t,v 1.10 2008/10/22 19:05:59 pchines Exp $

use strict;
use Test;
BEGIN {
    $main::tests = 21;
    plan tests => $main::tests
}
END {
    print "not ok 1\n" unless $main::loaded;
}
use NHGRI::Db::Connector;
ok $main::loaded = 1;

my $program = './dbc_passwd';
my $compile_result = `perl -wcTI blib/lib $program 2>&1`;
ok $compile_result =~ /syntax OK/;
my $pod_syntax = `podchecker $program 2>&1`;
ok $pod_syntax =~ /syntax OK/;

eval { require Test::Cmd; };
if ($@) {
    for (4..$main::tests) {
        skip("skip Test::Cmd module not available",1);
    }
    exit;
}

my $test = Test::Cmd->new(
        prog => $program,
		interpreter => 'perl -I blib/lib',
        workdir => '',
        );
ok($test->subdir('shared', 'private'), 2, "create subdirs");

$test->run(args => '-u');       # produce short help
ok($test->stderr(), qr/^Usage:/);
$test->run(args => '-h');       # produce option help
ok($test->stdout(), qr/Options:/);
$test->run(args => '-m');       # produce long help
ok($test->stdout(), qr/DBC_PASSWD/);
$test->run(args => '-v');       # display version
ok($test->stderr(), qr/^dbc_passwd, Revision/);

$test->run(args => 'too many args');    # too many args
ok($test->stdout(), qr/^Usage/);

my $shared_dir = $test->workpath("shared");
$test->run(args => "-dir $shared_dir"); # no default realm
ok($test->stderr(), qr/cannot be found/, "realm does not exist");

my $rh;
my $change_password = 0;
if (-f "test.live") {
    $rh = NHGRI::Db::Connector->read_realm_file(-filename => 'test.live');
    $change_password = 1;
}
elsif (-f "test") {
    $rh = NHGRI::Db::Connector->read_realm_file(-filename => 'test');
}
else {
    skip("skip no test realm",0) for (1..11);
    exit 0;
}
ok($test->write(["shared","default"], << "REALM"));
DBD=$rh->{DBD}
SERVER=$rh->{SERVER}
USER=$rh->{USER}
PASS=$rh->{PASS}
REALM

$test->run(args => "-dir $shared_dir", stdin => "wrong_password\n");
ok($test->stderr(), qr/Password does not match/);

my $stdin = "$rh->{PASS}\nnew_password\ndifferent\n";
$test->run(args => "-dir $shared_dir", stdin => $stdin);
ok($test->stderr(), qr/different/);

if ($change_password) {
    $stdin = "$rh->{PASS}\nnew_pass\nnew_pass\n";
    ok($test->run(args => "-dir $shared_dir", stdin => $stdin),
            0, "changed password");
    ok($test->stdout(), qr/Database password successfully set/);
    ok($test->stdout(), qr/Realm file successfully updated/);
    my $dbc = NHGRI::Db::Connector->new(-connection_dir => $shared_dir);
    my $rh_new = $dbc->read_realm_file();
    ok($rh_new->{PASS}, "new_pass", "password changed in realm file");
    ok($dbc->connect());
    $stdin = "new_pass\n$rh->{PASS}\n$rh->{PASS}\n";
    ok($test->run(args => "-dir $shared_dir", stdin => $stdin),
            0, "changed password back");
    ok($test->stdout(), qr/Database password successfully set/);
    ok($test->stdout(), qr/Realm file successfully updated/);
}
else {
    skip("skip not changing live password",0) for (1..8);
}
