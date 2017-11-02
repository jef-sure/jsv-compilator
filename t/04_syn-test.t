use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../t";
use Test::Most qw(!any !none);
use Data::Walk;
use JSON::Pointer;
use JSV::Compiler;
use List::Util qw'none any notall';
use feature qw(say);

my $jsv = JSV::Compiler->new;
$jsv->load_schema(
    {   type       => "object",
        properties => {
            foo => {type => "integer"},
            bar => {type => "string"}
        },
        required => ["foo"]
    }
);

my $vcode = $jsv->compile();

my $test_sub_txt = <<"SUB";
  sub { 
      my \$errors = []; 
      $vcode; 
      return "\@\$errors" if \@\$errors;
      return "valid" if \@\$errors == 0;
  }
SUB
my $test_sub = eval $test_sub_txt;

is($test_sub->({}), "foo is required", "foo is required");
is($test_sub->({foo => 1}), "valid", "foo is ok");
is($test_sub->({foo => 10, bar => "xyz"}), "valid", "foo and bar are ok");
is($test_sub->({foo => 1.2, bar => "xyz"}), "foo does not look like integer number", "foo is not integer");

done_testing();
