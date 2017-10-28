use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../t";
use Test::Most qw(!any !none);
use Data::Walk;
use JSON::Pointer;
use JSV::Compilator;
use List::Util qw'none any notall';

my $jsc          = JSV::Compilator->new();
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

$jsc->{original_schema} = {
    "\$schema"             => "http://json-schema.org/draft-06/schema#",
    "type"                 => "object",
    "properties"           => {"/" => $entry_schema},
    "patternProperties"    => {"^(/[^/]+)+\$" => $entry_schema},
    "additionalProperties" => 0,
    "required"             => ["/"]
};

$jsc->_resolve_references;

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

# do you want to know how generated function looks like?

# explain $test_sub_txt;

# sub { my $errors = []; if('HASH' eq ref($_[0])) {
# if('HASH' eq ref($_[0]->{'/'})) {
# if('ARRAY' eq ref($_[0]->{'/'}->{'options'})) {
#   push @$errors, '//options must contain not less than 1 items' if @{$_[0]->{'/'}->{'options'}} < 1;
#   { my %seen;
#     for (@{$_[0]->{'/'}->{'options'}}) {
#       if($seen{$_}) { push @$errors, '//options must contain only unique items'; last }
#       $seen{$_} = 1;
#     };
#   }
#   { my $tf = sub { if(defined($_[0])) {
# }
#  };
#     $tf->($_, "//options") for (@{$_[0]->{'/'}->{'options'}});
#   }
# }
# if(defined($_[0]->{'/'}->{'fstype'})) {
#   push @$errors, "//fstype must be on of 'ext3', 'ext4', 'btrfs'" if none {$_ eq $_[0]->{'/'}->{'fstype'}} ('ext3', 'ext4', 'btrfs');
# }
# if(defined($_[0]->{'/'}->{'readonly'})) {
# }
# if('HASH' eq ref($_[0]->{'/'}->{'storage'})) {
#   {  my @oneOf = (  sub {my $errors = []; if('HASH' eq ref($_[0])) {
# if(defined($_[0]->{'type'})) {
#   push @$errors, "//storage/type must be on of 'disk'" if none {$_ eq $_[0]->{'type'}} ('disk');
# }
# else {
#   push @$errors, "//storage/type is required";
# }
# if(defined($_[0]->{'device'})) {
#   push @$errors, "//storage/device does not match pattern" if $_[0]->{'device'} !~ /^\/dev\/[^\/]+(\/[^\/]+)*$/;
# }
# else {
#   push @$errors, "//storage/device is required";
# }
#   {
#     my %allowed_props = ('type', undef, 'device', undef);
#     my @unallowed_props = grep {!exists $allowed_props{$_} } keys %{$_[0]};
#     push @$errors, "//storage contains not allowed properties: @unallowed_props"  if @unallowed_props;
#   }
# }
# else {
#   push @$errors, "//storage is required";
# }
# ; @$errors == 0}
# ,
#   sub {my $errors = []; if('HASH' eq ref($_[0])) {
# if(defined($_[0]->{'label'})) {
#   push @$errors, "//storage/label does not match pattern" if $_[0]->{'label'} !~ /^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$/;
# }
# else {
#   push @$errors, "//storage/label is required";
# }
# if(defined($_[0]->{'type'})) {
#   push @$errors, "//storage/type must be on of 'disk'" if none {$_ eq $_[0]->{'type'}} ('disk');
# }
# else {
#   push @$errors, "//storage/type is required";
# }
#   {
#     my %allowed_props = ('label', undef, 'type', undef);
#     my @unallowed_props = grep {!exists $allowed_props{$_} } keys %{$_[0]};
#     push @$errors, "//storage contains not allowed properties: @unallowed_props"  if @unallowed_props;
#   }
# }
# else {
#   push @$errors, "//storage is required";
# }
# ; @$errors == 0}
# ,
#   sub {my $errors = []; if('HASH' eq ref($_[0])) {
# if(defined($_[0]->{'remotePath'})) {
#   push @$errors, "//storage/remotePath does not match pattern" if $_[0]->{'remotePath'} !~ /^(\/[^\/]+)+$/;
# }
# else {
#   push @$errors, "//storage/remotePath is required";
# }
# if(defined($_[0]->{'type'})) {
#   push @$errors, "//storage/type must be on of 'nfs'" if none {$_ eq $_[0]->{'type'}} ('nfs');
# }
# else {
#   push @$errors, "//storage/type is required";
# }
# if(defined($_[0]->{'server'})) {
# }
# else {
#   push @$errors, "//storage/server is required";
# }
#   {
#     my %allowed_props = ('server', undef, 'type', undef, 'remotePath', undef);
#     my @unallowed_props = grep {!exists $allowed_props{$_} } keys %{$_[0]};
#     push @$errors, "//storage contains not allowed properties: @unallowed_props"  if @unallowed_props;
#   }
# }
# else {
#   push @$errors, "//storage is required";
# }
# ; @$errors == 0}
# ,
#   sub {my $errors = []; if('HASH' eq ref($_[0])) {
# if(defined($_[0]->{'sizeInMB'})) { {
#   if($_[0]->{'sizeInMB'} !~ /^(?:(?:[-+]?)(?:[0123456789]+))$/){ push @$errors, '//storage/sizeInMB does not look like integer number'; last }
#   push @$errors, '//storage/sizeInMB must be not less than 16' if $_[0]->{'sizeInMB'} < 16;
#   push @$errors, '//storage/sizeInMB must be not greater than 512' if $_[0]->{'sizeInMB'} > 512;
# } }
# else {
#   push @$errors, "//storage/sizeInMB is required";
# }
# if(defined($_[0]->{'type'})) {
#   push @$errors, "//storage/type must be on of 'tmpfs'" if none {$_ eq $_[0]->{'type'}} ('tmpfs');
# }
# else {
#   push @$errors, "//storage/type is required";
# }
#   {
#     my %allowed_props = ('sizeInMB', undef, 'type', undef);
#     my @unallowed_props = grep {!exists $allowed_props{$_} } keys %{$_[0]};
#     push @$errors, "//storage contains not allowed properties: @unallowed_props"  if @unallowed_props;
#   }
# }
# else {
#   push @$errors, "//storage is required";
# }
# ; @$errors == 0}
# );
#     my $m = 0; for my $t (@oneOf) { ++$m if $t->($_[0]->{'/'}->{'storage'}, "//storage"); last if $m > 1; }    push @$errors, "//storage doesn't match exactly one required schema" if $m != 1;  }
# }
# else {
#   push @$errors, "//storage is required";
# }
# }
# else {
#   push @$errors, "/ is required";
# }
#   { my @props = grep {/^(\/[^\/]+)+$/} keys %{$_[0]};    my %defined_props = ('/', undef);
#     @props = grep {!exists $defined_props{$_} } @props;
#     my $tf = sub { if('HASH' eq ref($_[0])) {
# if('ARRAY' eq ref($_[0]->{'options'})) {
#   push @$errors, '$_[1]/options must contain not less than 1 items' if @{$_[0]->{'options'}} < 1;
#   { my %seen;
#     for (@{$_[0]->{'options'}}) {
#       if($seen{$_}) { push @$errors, '$_[1]/options must contain only unique items'; last }
#       $seen{$_} = 1;
#     };
#   }
#   { my $tf = sub { if(defined($_[0])) {
# }
#  };
#     $tf->($_, "$_[1]/options") for (@{$_[0]->{'options'}});
#   }
# }
# if(defined($_[0]->{'fstype'})) {
#   push @$errors, "$_[1]/fstype must be on of 'ext3', 'ext4', 'btrfs'" if none {$_ eq $_[0]->{'fstype'}} ('ext3', 'ext4', 'btrfs');
# }
# if(defined($_[0]->{'readonly'})) {
# }
# if('HASH' eq ref($_[0]->{'storage'})) {
#   {  my @oneOf = (  sub {my $errors = []; if('HASH' eq ref($_[0])) {
# if(defined($_[0]->{'type'})) {
#   push @$errors, "$_[1]/storage/type must be on of 'disk'" if none {$_ eq $_[0]->{'type'}} ('disk');
# }
# else {
#   push @$errors, "$_[1]/storage/type is required";
# }
# if(defined($_[0]->{'device'})) {
#   push @$errors, "$_[1]/storage/device does not match pattern" if $_[0]->{'device'} !~ /^\/dev\/[^\/]+(\/[^\/]+)*$/;
# }
# else {
#   push @$errors, "$_[1]/storage/device is required";
# }
#   {
#     my %allowed_props = ('type', undef, 'device', undef);
#     my @unallowed_props = grep {!exists $allowed_props{$_} } keys %{$_[0]};
#     push @$errors, "$_[1]/storage contains not allowed properties: @unallowed_props"  if @unallowed_props;
#   }
# }
# else {
#   push @$errors, "$_[1]/storage is required";
# }
# ; @$errors == 0}
# ,
#   sub {my $errors = []; if('HASH' eq ref($_[0])) {
# if(defined($_[0]->{'label'})) {
#   push @$errors, "$_[1]/storage/label does not match pattern" if $_[0]->{'label'} !~ /^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$/;
# }
# else {
#   push @$errors, "$_[1]/storage/label is required";
# }
# if(defined($_[0]->{'type'})) {
#   push @$errors, "$_[1]/storage/type must be on of 'disk'" if none {$_ eq $_[0]->{'type'}} ('disk');
# }
# else {
#   push @$errors, "$_[1]/storage/type is required";
# }
#   {
#     my %allowed_props = ('label', undef, 'type', undef);
#     my @unallowed_props = grep {!exists $allowed_props{$_} } keys %{$_[0]};
#     push @$errors, "$_[1]/storage contains not allowed properties: @unallowed_props"  if @unallowed_props;
#   }
# }
# else {
#   push @$errors, "$_[1]/storage is required";
# }
# ; @$errors == 0}
# ,
#   sub {my $errors = []; if('HASH' eq ref($_[0])) {
# if(defined($_[0]->{'remotePath'})) {
#   push @$errors, "$_[1]/storage/remotePath does not match pattern" if $_[0]->{'remotePath'} !~ /^(\/[^\/]+)+$/;
# }
# else {
#   push @$errors, "$_[1]/storage/remotePath is required";
# }
# if(defined($_[0]->{'type'})) {
#   push @$errors, "$_[1]/storage/type must be on of 'nfs'" if none {$_ eq $_[0]->{'type'}} ('nfs');
# }
# else {
#   push @$errors, "$_[1]/storage/type is required";
# }
# if(defined($_[0]->{'server'})) {
# }
# else {
#   push @$errors, "$_[1]/storage/server is required";
# }
#   {
#     my %allowed_props = ('remotePath', undef, 'type', undef, 'server', undef);
#     my @unallowed_props = grep {!exists $allowed_props{$_} } keys %{$_[0]};
#     push @$errors, "$_[1]/storage contains not allowed properties: @unallowed_props"  if @unallowed_props;
#   }
# }
# else {
#   push @$errors, "$_[1]/storage is required";
# }
# ; @$errors == 0}
# ,
#   sub {my $errors = []; if('HASH' eq ref($_[0])) {
# if(defined($_[0]->{'sizeInMB'})) { {
#   if($_[0]->{'sizeInMB'} !~ /^(?:(?:[-+]?)(?:[0123456789]+))$/){ push @$errors, '$_[1]/storage/sizeInMB does not look like integer number'; last }
#   push @$errors, '$_[1]/storage/sizeInMB must be not less than 16' if $_[0]->{'sizeInMB'} < 16;
#   push @$errors, '$_[1]/storage/sizeInMB must be not greater than 512' if $_[0]->{'sizeInMB'} > 512;
# } }
# else {
#   push @$errors, "$_[1]/storage/sizeInMB is required";
# }
# if(defined($_[0]->{'type'})) {
#   push @$errors, "$_[1]/storage/type must be on of 'tmpfs'" if none {$_ eq $_[0]->{'type'}} ('tmpfs');
# }
# else {
#   push @$errors, "$_[1]/storage/type is required";
# }
#   {
#     my %allowed_props = ('sizeInMB', undef, 'type', undef);
#     my @unallowed_props = grep {!exists $allowed_props{$_} } keys %{$_[0]};
#     push @$errors, "$_[1]/storage contains not allowed properties: @unallowed_props"  if @unallowed_props;
#   }
# }
# else {
#   push @$errors, "$_[1]/storage is required";
# }
# ; @$errors == 0}
# );
#     my $m = 0; for my $t (@oneOf) { ++$m if $t->($_[0]->{'storage'}, "$_[1]/storage"); last if $m > 1; }
#     push @$errors, "$_[1]/storage doesn't match exactly one required schema" if $m != 1;  }
# }
# else {
#   push @$errors, "$_[1]/storage is required";
# }
# }
# else {
#   push @$errors, "$_[1] is required";
# }
#  };
#     for my $prop (@props) {
#       $tf->($_[0]->{$prop}, "${prop}");
#     };
#   }
#   {
#     my %allowed_props = ('/', undef);
#     my @unallowed_props = grep {!exists $allowed_props{$_} } keys %{$_[0]};
#     @unallowed_props = grep { !/^(\/[^\/]+)+$/ } @unallowed_props;
#     push @$errors, "(object) contains not allowed properties: @unallowed_props"  if @unallowed_props;
#   }
# }
# else {
#   push @$errors, "(object) is required";
# }
# ; print "@$errors\n" if @$errors; return @$errors == 0 }


done_testing();
