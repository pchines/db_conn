# $Id: pquery.t,v 1.1 2008/08/08 16:46:34 pchines Exp $
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);

plan tests => 31;

my ($Dbc);
eval q{
    use NHGRI::Db::Connector;
    $Dbc = NHGRI::Db::Connector->new(realm => 'test_mysql');
    my $dbh = $Dbc->connect();
    if ($dbh->get_info(17) ne 'MySQL') {
        undef $Dbc;
    }
};
if ($@) {
    undef $Dbc;
}

my $test_data = 't/test_data.txt';
my $cmd = "perl -w pquery.plx";
my $out;
like get_test_output("$cmd -h"), qr/usage/i, "help";
like get_test_output($cmd), qr/one.+query file/i, "need a query";
like get_test_output("$cmd -path t -list"), qr/no matching query files/i,
    "no queries found";

like get_test_output("podchecker pquery.plx"), qr/OK\.\n$/, "POD ok";

my $sql = "select count(*) from information_schema.tables;";
$out = get_test_output("$cmd -n", << "END_QUERY");
# Simple query with comments, but nothing else special
$sql
END_QUERY
is $out, "$sql\n", "simple query";

my $pquery = << 'END_QUERY';
#= Pvalue : p-value [.05]
#= Trait  : trait [height]
select snp, pvalue /*%.5f*/
  from results
 where pvalue <= {Pvalue} and trait = '{Trait}'
END_QUERY

$out = get_test_output("$cmd -template", $pquery);
is $out, $pquery, "returns template";
$out = get_test_output("$cmd -template -v Trait=bmi", $pquery);
is $out, << "END_TEMPLATE", "returns template with -var replacement";
#= Pvalue : p-value [.05]
select snp, pvalue /*%.5f*/
  from results
 where pvalue <= {Pvalue} and trait = 'bmi'
END_TEMPLATE
$out = get_test_output("$cmd -template -v Trait=\@$test_data", $pquery);
$out =~ s/\s$/\n/;
is $out, << "END_TEMPLATE", "returns template with list replacement";
#= Pvalue : p-value [.05]
select snp, pvalue /*%.5f*/
  from results
 where pvalue <= {Pvalue} and trait in ('bmi','hdl','ldl')
END_TEMPLATE

$out = get_test_output("$cmd -n -defaults", $pquery);
is $out, "select snp, pvalue /*%.5f*/\n  from results\n"
    . " where pvalue <= .05 and trait = 'height'\n", "param query";

$out = get_test_output("$cmd -n -defaults -strip", $pquery);
is $out, "select snp, pvalue \n  from results\n"
    . " where pvalue <= .05 and trait = 'height'\n",
    "param query strip comment";

$out = get_test_output("$cmd -n -v Pvalue=.1 -v Trait=weight", $pquery);
is $out, "select snp, pvalue /*%.5f*/\n  from results\n"
    . " where pvalue <= .1 and trait = 'weight'\n",
    "param query commandline vars";

$out = get_test_output("$cmd -n -v Pvalue=.1 -v Trait=\@$test_data",
        $pquery);
is $out, "select snp, pvalue /*%.5f*/\n  from results\n"
    . " where pvalue <= .1 and trait in ('bmi','hdl','ldl') ",
    "param query commandline list vars from file";

$out = get_test_output("$cmd -n -v Pvalue=.1 -v Trait=bmi,chol,whr",
        $pquery);
is $out, "select snp, pvalue /*%.5f*/\n  from results\n"
    . " where pvalue <= .1 and trait in ('bmi','chol','whr') ",
    "param query commandline list vars comma";

my $pq1 = $pquery;
$pq1 =~ s/#= Trait/#: Trait/;
$out = get_test_output("$cmd -n -v Pvalue=.1 -v Trait=bmi,chol,whr", $pq1);
is $out, "select snp, pvalue /*%.5f*/\n  from results\n"
    . " where pvalue <= .1 and trait = 'bmi,chol,whr'\n",
    "param query commandline non-list comma";

$out = get_test_output("$cmd -n -v Pvalue=.1 -v Trait=@/dev/null",
        $pquery);
is $out, "No non-comment lines in '/dev/null'; "
    . "this will not produce a valid query\n"
    . "select snp, pvalue /*%.5f*/\n  from results\n"
    . " where pvalue <= .1 and trait in () ",
    "param query commandline null list";

my $pq2 = $pquery . "and (trait = '{Trait}')";
$out = get_test_output("$cmd -n -debug -v Pvalue=.1 -v Trait=\@$test_data",
        $pq2);
is $out, "Read 3 items from '$test_data'\n"
    . "select snp, pvalue /*%.5f*/\n  from results\n"
    . " where pvalue <= .1 and trait in ('bmi','hdl','ldl') "
    . "and (trait in ('bmi','hdl','ldl') )",
    "param query with two list replacements (debug mode)";

$out = get_test_output("$cmd -n -v Pvalue=ANY -v Trait=ANY", $pq1);
is $out, "select snp, pvalue /*%.5f*/\n  from results\n"
    . " where 1=1 and trait = 'ANY'\n",
    "param query commandline ANY one non-any var";

$pquery =~ tr/{}/[]/;
$out = get_test_output("$cmd -n -defaults -op [ -cl ]", $pquery);
is $out, "select snp, pvalue /*%.5f*/\n  from results\n"
    . " where pvalue <= .05 and trait = 'height'\n",
    "use different variable delimiters";

$pquery = << "END_PQUERY";
## Printed comments
#= Chr      : [12]
#= ChrStart : [10kb]
#= ChrEnd   : [1.5mb]
select snp from snp_pos where chr = {Chr}
and pos >= {ChrStart} and pos <= {ChrEnd}
END_PQUERY

$out = get_test_output("$cmd -n -defaults", $pquery);
is $out, "Printed comments\nselect snp from snp_pos where chr = 12\n"
    . "and pos >= 10000 and pos <= 1500000\n",
    "defaults with kb/mb modifiers";

$out = get_test_output(
        "$cmd -n -v Chr=13 -v ChrStart=10.123kb -v ChrEnd=.05mb -limit 5",
        $pquery);
is $out, "Printed comments\nselect snp from snp_pos where chr = 13\n"
    . "and pos >= 10123 and pos <= 50000\n\nlimit 5",
    "substitutions with kb/mb modifiers, limit";

$out = get_test_output(
        "$cmd -n -def -v ChrStart=.1m -v ChrEnd=\@$test_data",
        $pquery);
like $out, qr/^Printed\scomments\n
Warning!\s+Attempting\sto\sreplace\sparameter\s'ChrEnd'\swith\sa\slist,
.*
select\ssnp\sfrom\ssnp_pos\swhere\schr\s=\s12\n
and\spos\s>=\s100000\sand\spos\s<=\s\{ChrEnd\}\n
/xs,
    "substitutions with non-allowed list replacement";

$out = get_test_output("$cmd -n -region ChrX:23.4m-23,567,890", $pquery);
is $out, "Printed comments\nselect snp from snp_pos where chr = 23\n"
    . "and pos >= 23400000 and pos <= 23567890\n",
    "region option";
$out = get_test_output("$cmd -n -region 20", $pquery);
is $out, "Printed comments\nselect snp from snp_pos where chr = 20\n"
    . "and 1=1 and 1=1\n",
    "region option, chr only";
$out = get_test_output("$cmd -n -region ANY", $pquery);
is $out, "Printed comments\nselect snp from snp_pos where 1=1\n"
    . "and 1=1 and 1=1\n",
    "region option, ANY";
$out = get_test_output("$cmd -n -region 1:2,345", $pquery);
is $out, "Printed comments\nselect snp from snp_pos where chr = 1\n"
    . "and pos >= 2345 and pos <= 2345\n",
    "region option, single position";

SKIP: {
    skip "No MySQL database connection in 'test_mysql' realm", 6 unless $Dbc;
    $pquery = << 'END_QUERY';
#= TableNamePrefix : [TABLE]
select table_name, table_catalog, avg_row_length /*%05d*/
from information_schema.TABLES
where table_schema = "information_schema"
and table_name like "{TableNamePrefix}%"
order by avg_row_length
END_QUERY
    $out = get_test_output("$cmd -def -db test_mysql", $pquery);
    # Row lengths vary for different MySQL versions
    my $expect = qr{
^table_name\ttable_catalog\tavg_row_length\n
TABLE_PRIVILEGES\t\t\d{5}\n
TABLE_CONSTRAINTS\t\t\d{5}\n
TABLES\t\t\d{5}\n
}x;
    like $out, $expect, "Simple query with defaults, formatting";
    $out = get_test_output(
        "$cmd -v TableNamePrefix=COLU -db test_mysql -sql -null .", $pquery);
    $expect = qr{
^\#\s/\*\sQuery\sexecuted\sat\s\d{4}-\d\d-\d\d\s\d+:\d\d:\d\d\sin\srealm\s'\w+'\s\*/\n
\#\sselect\stable_name,\stable_catalog,\savg_row_length\s/\*%05d\*/\n
\#\sfrom\sinformation_schema\.TABLES\n
\#\swhere\stable_schema\s=\s"information_schema"\n
\#\sand\stable_name\slike\s"COLU%"\n
\#\sorder\sby\savg_row_length\n
table_name\ttable_catalog\tavg_row_length\n
COLUMNS\t\.\t\d{5}\n
COLUMN_PRIVILEGES\t\.\t\d{5}\n
}x;
    like $out, $expect, "Simple query with prepended SQL, null values";

    $pquery = << 'END_QUERY';
#= TableNamePrefix : [TABLE]
select substr(table_name,1,10) as table_n, table_catalog,
    avg_row_length /*%06d*/
from information_schema.TABLES
where table_schema = "information_schema"
and table_name like "{TableNamePrefix}%"
order by avg_row_length
END_QUERY
    $out = get_test_output("$cmd -def -db test_mysql", $pquery);
    $expect = qr{
^table_n\ttable_catalog\tavg_row_length\n
TABLE_PRIV\t\t\d{6}\n
TABLE_CONS\t\t\d{6}\n
TABLES\t\t\d{6}\n
}x;
    like $out, $expect, "commas in function don't break formatting";

    $pquery = << 'END_QUERY';
#= TableNamePrefix : [TABLE]
select substr(table_name,locate("_",table_name)+1,10) as table_n, table_catalog,
    avg_row_length /*%06d*/
from information_schema.TABLES
where table_schema = "information_schema"
and table_name like "{TableNamePrefix}%"
order by avg_row_length
END_QUERY
    $out = get_test_output("$cmd -def -db test_mysql", $pquery);
    $expect = qr{
^table_n\ttable_catalog\tavg_row_length\n
PRIVILEGES\t\t\d{6}\n
CONSTRAINT\t\t\d{6}\n
TABLES\t\t\d{6}\n
}x;
    like $out, $expect, "commas in nested functions don't break formatting";

    $pquery = "##DefaultDb:test_mysql\n" . $pquery;
    $out = get_test_output("$cmd -def -sql", $pquery);
    ok $out =~ s/^DefaultDb:test_mysql\n//;
    like $out, qr/Query executed at.* in realm 'test_mysql'/,
        "Used DefaultDB";
}

sub get_test_output {
    my ($cmd, $data) = @_;
    my $file = "";
    if (defined $data) {
        my $fh;
        ($fh, $file) = tempfile();
        print $fh $data;
        close $fh;
    }
    my $out;
    print "Running: '$cmd $file 2>&1'\n";
    $out = `$cmd $file 2>&1`;
    if ($file) {
        unlink $file;
    }
    return $out;
}
