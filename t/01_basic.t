use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../t";
use Test::Most;
use JSV::Compilator;

my $jsc = JSV::Compilator->new();
$jsc->{full_schema} = {
	"\$schema"    => "http://json-schema.org/draft-06/schema#",
	"title"       => "Product",
	"description" => "A product from Acme's catalog",
	"type"        => "object",
	"properties"  => {
		"id" => {
			"description" => "The unique identifier for a product",
			"type"        => "integer"
		},
		"name" => {
			"description" => "Name of the product",
			"type"        => "string"
		},
		"price" => {
			"type"             => "number",
			"exclusiveMinimum" => 0
		},
		#		"tags" => {
		#			"type"        => "array",
		#			"items"       => {"type" => "string"},
		#			"minItems"    => 1,
		#			"uniqueItems" => 1
		#			}
	},
	"required" => ["id", "name", "price"]
};

my $ok_products = [
	{   "id"    => 2,
		"name"  => "An ice sculpture",
		"price" => 12.50,
	},
	{   "id"    => 3,
		"name"  => "A blue mouse",
		"price" => 25.50,
	}
];

my $bad_products = [
	{   "id"    => 2.5,
		"name"  => "An ice sculpture",
		"price" => 1,
	},
	{   "id"    => 3,
		"name"  => "A blue mouse",
		"price" => -1,
	}
];

my $res = $jsc->compile();
ok($res, "Compiled");

my $test_sub = eval $res;
is($@, '', "Successfully compiled");
explain $res if $@;

for my $p (@$ok_products) {
	ok($test_sub->($p), "Tested product");
}

for my $p (@$bad_products) {
	ok(!$test_sub->($p), "Tested product") or explain $res;
}
explain $res;
my $s = sub {
	!defined($_[0])
		|| defined($_[0])
		&& (
		1 == 1 && 'HASH' eq ref($_[0]) && !defined($_[0]->{price})
		|| defined($_[0]->{price})
		&& (1 == 1
			&& ($_[0]->{price}
				=~ /^(?:(?i)(?:[-+]?)(?:(?=[.]?[0123456789])(?:[0123456789]*)(?:(?:[.])(?:[0123456789]{0,}))?)(?:(?:[E])(?:(?:[-+]?)(?:[0123456789]+))|))$/
			)
		)
		&& !defined($_[0]->{id})
		|| defined($_[0]->{id}) && (1 == 1 && ($_[0]->{id} =~ /^(?:(?:[-+]?)(?:[0123456789]+))$/))
		 && !defined($_[0]->{name})
		|| defined($_[0]->{name}) && (1 == 1)
		);
};

done_testing();
