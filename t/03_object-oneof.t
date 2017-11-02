use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../t";
use Test::Most qw(!any !none);
use Data::Walk;
use JSON::Pointer;
use JSV::Compiler;
use List::Util qw'none any notall';

my $jsc          = JSV::Compiler->new();
my $entry_schema = {
    "id"          => "http://some.site.somewhere/entry-schema#",
    "\$schema"    => "http://json-schema.org/draft-06/schema#",
    "description" => "schema for an fstab entry",
    "type"        => "object",
    "required"    => ["storage"],
    "properties"  => {
        "storage" => {
            "type"  => "object",
            "oneOf" => [
                {"\$ref" => "#/definitions/diskDevice"},
                {"\$ref" => "#/definitions/diskUUID"},
                {"\$ref" => "#/definitions/nfs"},
                {"\$ref" => "#/definitions/tmpfs"}
            ]
        },
        "fstype"  => {"enum" => ["ext3", "ext4", "btrfs"]},
        "options" => {
            "type"        => "array",
            "minItems"    => 1,
            "items"       => {"type" => "string"},
            "uniqueItems" => 1
        },
        "readonly" => {"type" => "boolean"}
    },
    "definitions" => {
        "diskDevice" => {
            "properties" => {
                "type"   => {"enum" => ["disk"]},
                "device" => {
                    "type"    => "string",
                    "pattern" => "^/dev/[^/]+(/[^/]+)*\$"
                }
            },
            "required"             => ["type", "device"],
            "additionalProperties" => 0
        },
        "diskUUID" => {
            "properties" => {
                "type"  => {"enum" => ["disk"]},
                "label" => {
                    "type"    => "string",
                    "pattern" => "^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}\$"
                }
            },
            "required"             => ["type", "label"],
            "additionalProperties" => 0
        },
        "nfs" => {
            "properties" => {
                "type"       => {"enum" => ["nfs"]},
                "remotePath" => {
                    "type"    => "string",
                    "pattern" => "^(/[^/]+)+\$"
                },
                "server" => {
                    "type"  => "string",
                    "oneOf" => [{"format" => "hostname"}, {"format" => "ipv4"}, {"format" => "ipv6"}]
                }
            },
            "required"             => ["type", "server", "remotePath"],
            "additionalProperties" => 0
        },
        "tmpfs" => {
            "properties" => {
                "type"     => {"enum" => ["tmpfs"]},
                "sizeInMB" => {
                    "type"    => "integer",
                    "minimum" => 16,
                    "maximum" => 512
                }
            },
            "required"             => ["type", "sizeInMB"],
            "additionalProperties" => 0
        },
    },
};

# resolve references inside entry schema
walkdepth(
    +{
        wanted => sub {
            if (   ref $_ eq "HASH"
                && exists $_->{'$ref'}
                && !ref $_->{'$ref'}
                && keys %$_ == 1)
            {
                my $rv = $_->{'$ref'};
                $rv =~ s/.*#//;
                my $rp = JSON::Pointer->get($entry_schema, $rv);
                if ('HASH' eq ref $rp) {
                    %$_ = %$rp;
                }

            }
        },
    },
    $entry_schema
);

$jsc->load_schema(
    {   "\$schema"             => "http://json-schema.org/draft-06/schema#",
        "type"                 => "object",
        "properties"           => {"/" => $entry_schema},
        "patternProperties"    => {"^(/[^/]+)+\$" => $entry_schema},
        "additionalProperties" => 0,
        "required"             => ["/"]
    }
);

my $ok_path = [
    {
        "/" => {
            "storage" => {
                "type"   => "disk",
                "device" => "/dev/sda1"
            },
            "fstype"   => "btrfs",
            "readonly" => 1
        },
        "/var" => {
            "storage" => {
                "type"  => "disk",
                "label" => "8f3ba6f4-5c70-46ec-83af-0d5434953e5f"
            },
            "fstype"  => "ext4",
            "options" => ["nosuid"]
        },
        "/tmp" => {
            "storage" => {
                "type"     => "tmpfs",
                "sizeInMB" => 64
            }
        },
        "/var/www" => {
            "storage" => {
                "type"       => "nfs",
                "server"     => "my.nfs.server",
                "remotePath" => "/exports/mypath"
            }
        }
    },
];

my $bad_path = [{"/home" => {},},];

my $res = $jsc->compile();
ok($res, "Compiled");
my $test_sub_txt = "sub { my \$errors = []; $res; print \"\@\$errors\\n\" if \@\$errors; return \@\$errors == 0 }\n";
my $test_sub     = eval $test_sub_txt;

is($@, '', "Successfully compiled");
explain $test_sub_txt if $@;

for my $p (@$ok_path) {
    ok($test_sub->($p), "Tested path");
}

for my $p (@$bad_path) {
    ok(!$test_sub->($p), "Tested path") or explain $res;
}

done_testing();

# do you want to know how generated function looks like?

# explain $test_sub_txt;

