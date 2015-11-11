#/usr/bin/perl -w
# $Id: dbc_realm.t,v 1.14 2009/12/24 20:12:59 pchines Exp $

use strict;
use Test;
BEGIN {
    $main::tests = 42;
    plan tests => $main::tests
}
END {
    print "not ok 1\n" unless $main::loaded;
}
use NHGRI::Db::Connector;
ok $main::loaded = 1;

my $program = './dbc_realm';
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
		interpreter  => 'perl -I blib/lib',
        workdir => '',
        );
ok($test->subdir('shared', 'private'), 2, "create subdirs");

$test->run(args => '-usage');   # produce short help
ok($test->stderr(), qr/Usage:/);
$test->run(args => '-h');       # produce option help
ok($test->stdout(), qr/Options:/);
$test->run(args => '-man');     # produce long help
ok($test->stdout(), qr/DBC_REALM/i);
$test->run(args => '-v');       # display version
ok($test->stderr(), qr/^dbc_realm, Revision/);

$test->run(args => 'too many args');    # too many args
ok($test->stdout(), qr/^Usage/);

my $shared_dir = $test->workpath("shared");
$test->run(args => "-dir $shared_dir -q default");  # no source realm
ok($test->stderr(), qr/no default values/, "no defaults");
ok($test->stderr(), qr/write_realm_file: DBD parameter/, "DBD required");

$test->run(args => "--dir $shared_dir --from not_there -q new_realm");
ok($test->stderr(), qr/^The database realm 'not_there' cannot be found/);

my $src_data = << "REALM";
DBD=Mybase
SERVER=server
USER=username
PASS=password
DATABASE=
REALM

ok($test->write(['shared','from_realm'], $src_data));
$test->run(args => "--dir $shared_dir --from from_realm -q"); # no dest
ok($test->stderr(), qr/^No realm specified.  Aborting.\n(?:stty.*\n)?$/);

ok($test->run(args=>"-dir $shared_dir -from from_realm -q -nocheck new_realm"),
        0, "create identical new realm");
my $new_data;
ok($test->read(\$new_data, ['shared','new_realm']), 1, "read new realm file");
ok($new_data, $src_data, "compare copied realm data");

ok($test->run(
    args => "-dir $shared_dir -q -user newuser -pass newpass -noc new_realm"),
    0, "change user and pass non-interactively");
ok($test->stderr(), qr/^(?:stty.*\n)?$/);
ok($test->stdout(), '');
ok($test->read(\$new_data, ['shared','new_realm']), 1, "read new realm file");
ok($new_data, << "NEW_REALM", "compare updated realm data");
DBD=Mybase
SERVER=server
USER=newuser
PASS=newpass
DATABASE=
NEW_REALM

my $stdin = "new_realm\n\n\nuser1\npass1\n\n";
ok($test->run(args => "--dir $shared_dir -nocheck", stdin => $stdin),
        0, "interactive");
ok($test->stdout(), qr/Successfully wrote 'new_realm' realm file.\n$/);
ok($test->read(\$new_data, ['shared','new_realm']), 1, "read new realm file");
ok($new_data, << "NEW_REALM", "compare updated realm data");
DBD=Mybase
SERVER=server
USER=user1
PASS=pass1
DATABASE=
NEW_REALM

ok($test->run(args => "-dir $shared_dir -list"), 0, "list realms");
ok($test->stdout(), << "LIST", "test list of realms");
Realm           DBD     Server                       Database        Username  
from_realm      Mybase  server                                       username  
new_realm       Mybase  server                                       user1     
LIST
ok($test->run(args => "-dir $shared_dir -list -tab ,"), 0, "list realms csv");
ok($test->stdout(), << "LIST", "test list of realms");
Realm,DBD,Server,Database,Username
from_realm,Mybase,server,,username
new_realm,Mybase,server,,user1
LIST

if (-e "./test") {
    ok($test->run(args => "-dir . -q -check test"), 0, "run -check");
}
else {
    skip("skip dbc_realm -check; no realm to check",1);
}
ok($test->run(args => "-dir $shared_dir -q -check from_realm"));
ok($test->stderr(), qr/install_driver.*Can't locate/, "can't find driver");
ok($test->run(args => "-dir $shared_dir -q -check no_realm"));
ok($test->stderr(), qr/realm 'no_realm' cannot be found/, "can't find realm");

ok($test->run(args => "-dir $shared_dir -q -q -delete no_realm"));
ok($test->stderr(), qr/ealm file '.*no_realm' does not exist/,
        "can't find realm");
ok(-e $test->workpath("shared","from_realm"),1,"file exists");
ok($test->run(args => "-dir $shared_dir -q -delete from_realm", stdin => "y\n"),
        0, "delete from_realm");
ok($test->stdout(), qr/you sure.*Successfully removed/, "delete stdout");
ok($test->stderr(), "", "delete stderr");
ok(!-e $test->workpath("shared","from_realm"));

