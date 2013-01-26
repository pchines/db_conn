# $Id: write.t,v 1.4 2003/01/07 02:28:43 pchines Exp $

use strict;
use Test; 
BEGIN { plan tests => 24 } 
END   { print "not ok 1\n" unless $main::loaded; }
use File::Spec;
use DBIx::Connector;
$main::loaded = 1;
ok 1;

my $test_realm = 'test';
my $test_dir   = 't';
my %test_param = (
        DBD     => 'Mybase',
        SERVER  => 'host=here;port=22',
        USER    => 'shmoozer',
        PASS    => 'stones',
        );
my $file = File::Spec->join($test_dir, $test_realm);

# Test write with explicit filename
unlink $file;
ok !-e $file;
my $write_ok = DBIx::Connector->write_realm_file(
        %test_param, -filename => $file);
ok $write_ok;
ok -e $file;

# Test read with explicit connection_dir
my $dbc = DBIx::Connector->new(
        -realm => $test_realm,
        -connection_dir => $test_dir,
        );
ok $dbc;
check_values($dbc);

# Test write to private connection dir
$DBIx::Connector::PRIVATE_CONNECTION_DIR = $test_dir;
unlink $file;
ok !-e $file;
$write_ok = DBIx::Connector->write_realm_file(
        %test_param, -realm => $test_realm);
ok $write_ok;
ok -e $file;

$dbc = DBIx::Connector->new(
        -realm => $test_realm,
        );
ok $dbc;
check_values($dbc);

# Test write to shared connection dir
$test_param{'DBD'} = "Shmybase";
my $sh_dir = "t/shared";
mkdir $sh_dir, 0755;
$DBIx::Connector::SHARED_CONNECTION_DIR = $sh_dir;
my $sh_file = File::Spec->join($sh_dir, $test_realm);
unlink $sh_file;
ok !-e $sh_file;
$write_ok = DBIx::Connector->write_realm_file(
        %test_param, -shared => 1, -realm => $test_realm);
ok $write_ok;
ok -e $sh_file;

# Should read private version
$dbc = DBIx::Connector->new( -realm => $test_realm );
my $rh = $dbc->read_realm_file();
ok $rh->{'DBD'}, "Mybase";

# Read with static method calls
$rh = DBIx::Connector->read_realm_file( -filename => $sh_file );
ok $rh->{'DBD'}, "Shmybase";

# Reads private version if it exists
$rh = DBIx::Connector->read_realm_file( -realm => $test_realm );
ok $rh->{'DBD'}, "Mybase";

# But falls back to shared version
unlink $file;
$rh = DBIx::Connector->read_realm_file( -realm => $test_realm );
ok $rh->{'DBD'}, "Shmybase";

unlink $sh_file;
rmdir $sh_dir;

sub check_values {
    my $dbc = shift;
    my $rh_param = $dbc->read_realm_file();
    foreach my $key (sort keys %test_param) {
        ok $rh_param->{$key}, $test_param{$key}, "reading $key";
    }
}
