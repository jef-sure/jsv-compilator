package JSV::Compilator;
use strict;
use warnings;
use Data::Walk;
use JSON;
use JSON::Pointer;
use Path::Tiny;
use Carp;
use Storable 'dclone';
use Data::Dumper;
use Regexp::Common('RE_ALL', 'Email::Address', 'URI', 'time');

sub new {
    my ($class, %args) = @_;
    bless {
        original_schema => {},
        full_schema     => {}
    }, $class;
}

sub load_schema {
    my ($self, $file) = @_;
    croak "Unreadable file" if !-r $file;
    if ($file =~ /\.yaml$/i || $file =~ /\.yml$/i) {
        require YAML::XS;
        $self->{original_schema} = YAML::XS::LoadFile($file);
    } elsif ($file =~ /\.json/i) {
        $self->{original_schema} = decode_json(path($file)->slurp_raw);
    } else {
        croak "Unknown file type: must be .json or .yaml";
    }
    $self->_resolve_references;
    return $self;
}

sub _resolve_references {
    my $self = $_[0];
    $self->{full_schema} = dclone $self->{original_schema};
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
                    my $rp = JSON::Pointer->get($self->{full_schema}, $rv);
                    if ('HASH' eq ref $rp) {
                        %$_ = %$rp;
                    }

                }
            },
        },
        $self->{full_schema}
    );
    return $self;
}

sub compile {
    my ($self, %opts) = @_;
    local $self->{coersion} = $opts{coersion} // 0;
    local $self->{to_json}  = $opts{to_json}  // 0;
    local $self->{required_modules} = {};
    my $input_sym = $opts{input_symbole} // '$_[0]';
    my $schema    = $self->{full_schema};
    my $type      = 'string';
    $type = $schema->{type} // _guess_schema_type($schema);
    my $is_required = $opts{is_required} // $type eq 'object' || 0;
    my $val_func    = "_validate_$type";
    my $val_expr    = $self->$val_func($input_sym, $schema, "", $is_required);
    return $val_expr;
}

# type: six primitive types ("null", "boolean", "object", "array", "number", or "string"), or "integer"

sub _sympt_to_path {
    my ($sympt) = @_;
    $sympt =~ s!^[^\{\}]+!/!;
    $sympt =~ s![\{\}]+!/!g;
    $sympt;
}

sub _guess_schema_type {
    my $shmpt = $_[0];
    return 'object'
        if defined $shmpt->{additionalProperties}
        or $shmpt->{patternProperties}
        or $shmpt->{properties}
        or defined $shmpt->{minProperties}
        or defined $shmpt->{maxProperties};
    return 'array'
        if defined $shmpt->{additionalItems}
        or defined $shmpt->{uniqueItems}
        or $shmpt->{items}
        or defined $shmpt->{minItems}
        or defined $shmpt->{maxItems};
    return 'number'
        if defined $shmpt->{minimum}
        or defined $shmpt->{maximum}
        or defined $shmpt->{exclusiveMinimum}
        or defined $shmpt->{exclusiveMaximum}
        or defined $shmpt->{multipleOf};
    return 'string';
}

sub _quote_var {
    my $s = $_[0];
    my $d = Data::Dumper->new([$s]);
    $d->Terse(1);
    my $qs = $d->Dump;
    substr($qs, -1, 1, '') if substr($qs, -1, 1) eq "\n";
    return $qs;
}

#<<<
my %formats = (
	'date-time' => $RE{time}{iso},
	email       => $RE{Email}{Address},
	uri         => $RE{URI},
	hostname    => '(?:(?:(?:(?:[a-zA-Z0-9][-a-zA-Z0-9]*)?[a-zA-Z0-9])[.])*'
				 . '(?:[a-zA-Z][-a-zA-Z0-9]*[a-zA-Z0-9]|[a-zA-Z])[.]?)',
	ipv4        => $RE{net}{IPv4},
	ipv6        => $RE{net}{IPv6},
);
#>>>

sub _validate_null {
    my ($self, $sympt, $schmptm, $path) = @_;
    return "push \@\$errors, '$path must be null' if defined($sympt);\n";
}

sub _validate_boolean {
    my ($self, $sympt, $schmpt, $path, $is_required) = @_;
    my $r = '';
    if (defined $schmpt->{default}) {
        my $val = _quote_var($schmpt->{default});
        $r = "$sympt = $val if not defined $sympt;\n";
    }
    $r .= "if(defined($sympt)) {\n";
    if (defined $schmpt->{const}) {
        $r .= "  { no warnings 'undefined';\n";
        $r .= "    push \@\$errors, '$path must be '.($schmpt->{const}?'true':'false') if $sympt != $schmpt->{const}\n";
        $r .= "  }\n";
    }
    if ($self->{to_json}) {
        $r = "  $sympt = (($sympt)? \\1: \\0);\n";
    } elsif ($self->{coersion}) {
        $r = "  $sympt = (($sympt)? 1: 0);\n";
    }
    $r .= "}\n";
    if ($is_required) {
        $r .= "else {\n";
        $r .= "  push \@\$errors, \"$path is required\";\n";
        $r .= "}\n";
    }
    return $r;
}

sub _validate_string {
    my ($self, $sympt, $schmpt, $path, $is_required) = @_;
    my $r = '';
    if (defined $schmpt->{default}) {
        my $val = _quote_var($schmpt->{default});
        $r = "$sympt = $val if not defined $sympt;\n";
    }
    $r .= "if(defined($sympt)) {\n";
    if (defined $schmpt->{maxLength}) {
        $r .= "  push \@\$errors, '$path length must be not greater than ";
        $r .= "$schmpt->{maxLength}' if length($sympt) > $schmpt->{maxLength};\n";
    }
    if (defined $schmpt->{minLength}) {
        $r .= "  push \@\$errors, '$path length must be not less than ";
        $r .= "$schmpt->{minLength}' if length($sympt) < $schmpt->{minLength};\n";
    }
    if (defined $schmpt->{const}) {
        my $val = _quote_var($schmpt->{const});
        $r .= "  push \@\$errors, \"$path must be $schmpt->{const}\" if $sympt ne $val;\n";
    }
    if (defined $schmpt->{pattern}) {
        my $pattern = $schmpt->{pattern};
        $pattern =~ s/\\Q(.*?)\\E/quotemeta($1)/eg;
        $pattern =~ s/\\Q(.*)$/quotemeta($1)/eg;
        $pattern =~ s/"/\\"/g;
        $pattern =~ s|/|\\/|g;
        $r .= "  push \@\$errors, \"$path does not match pattern\" if $sympt !~ /$pattern/;\n";
    }
    if ($schmpt->{enum} && 'ARRAY' eq ref($schmpt->{enum}) && @{$schmpt->{enum}}) {
        my $can_list = join ", ", map {_quote_var($_)} @{$schmpt->{enum}};
        $self->{required_modules}{'List::Util'}{none} = 1;
        $r .= "  push \@\$errors, \"$path must be on of $can_list\" if none {\$_ eq $sympt} ($can_list);\n";
    }
    if ($schmpt->{format} && $formats{$schmpt->{format}}) {
        $r .= "  push \@\$errors, \"$path does not match format $schmpt->{format}\"";
        $r .= " if $sympt !~ /^$formats{$schmpt->{format}}\$/;\n";
    }
    if ($self->{to_json} || $self->{coersion}) {
        $r .= "  $sympt = \"$sympt\";\n";
    }
    $r .= "}\n";
    if ($is_required) {
        $r .= "else {\n";
        $r .= "  push \@\$errors, \"$path is required\";\n";
        $r .= "}\n";
    }
    return $r;
}

sub _validate_any_number {
    my ($self, $sympt, $schmpt, $path, $is_required, $re, $ntype) = @_;
    my $r = '';
    $ntype ||= '';
    if (defined $schmpt->{default}) {
        my $val = _quote_var($schmpt->{default});
        $r = "$sympt = $val if not defined $sympt;\n";
    }
    $r .= "if(defined($sympt)) { {\n";
    $r .= "  if($sympt !~ /^$re\$/){ push \@\$errors, '$path does not look like $ntype number'; last }\n";
    if (defined $schmpt->{minimum}) {
        $r .= "  push \@\$errors, '$path must be not less than $schmpt->{minimum}'";
        $r .= " if $sympt < $schmpt->{minimum};\n";
    }
    if (defined $schmpt->{exclusiveMinimum}) {
        $r .= "  push \@\$errors, '$path must be greater than $schmpt->{exclusiveMinimum}'";
        $r .= " if $sympt <= $schmpt->{exclusiveMinimum};\n";
    }
    if (defined $schmpt->{maximum}) {
        $r .= "  push \@\$errors, '$path must be not greater than $schmpt->{maximum}'";
        $r .= " if $sympt > $schmpt->{maximum};\n";
    }
    if (defined $schmpt->{exclusiveMaximum}) {
        $r .= "  push \@\$errors, '$path must be less than $schmpt->{exclusiveMaximum}'";
        $r .= " if $sympt >= $schmpt->{exclusiveMaximum};\n";
    }
    if (defined $schmpt->{const}) {
        $r .= "  push \@\$errors, '$path must be $schmpt->{const}' if $sympt != $schmpt->{const};\n";
    }
    if ($schmpt->{multipleOf}) {
        $self->{required_modules}{'POSIX'}{floor} = 1;
        $r .= "  push \@\$errors, '$path must be multiple of $schmpt->{multipleOf}'";
        $r .= " if $sympt / $schmpt->{multipleOf} !=  floor($sympt / $schmpt->{multipleOf});\n";
    }
    if ($schmpt->{enum} && 'ARRAY' eq ref($schmpt->{enum}) && @{$schmpt->{enum}}) {
        my $can_list = join ", ", map {_quote_var($_)} @{$schmpt->{enum}};
        $self->{required_modules}{'List::Util'}{none} = 1;
        $r .= "  push \@\$errors, '$path must be on of $can_list' if none {$_ == $sympt} ($can_list);\n";
    }
    if ($schmpt->{format} && $formats{$schmpt->{format}}) {
        $r .= "  push \@\$errors, '$path does not match format $schmpt->{format}'";
        $r .= " if $sympt !~ /^$formats{$schmpt->{format}}\$/;\n";
    }
    if ($self->{to_json} || $self->{coersion}) {
        $r .= "  $sympt += 0;\n";
    }
    $r .= "} }\n";
    if ($is_required) {
        $r .= "else {\n";
        $r .= "  push \@\$errors, \"$path is required\";\n";
        $r .= "}\n";
    }
    return $r;

}

sub _validate_number {
    my ($self, $sympt, $schmpt, $path, $is_required) = @_;
    return $self->_validate_any_number($sympt, $schmpt, $path, $is_required, $RE{num}{real});
}

sub _validate_integer {
    my ($self, $sympt, $schmpt, $path, $is_required) = @_;
    return $self->_validate_any_number($sympt, $schmpt, $path, $is_required, $RE{num}{int}, "integer");
}

sub _validate_object {
    my ($self, $sympt, $schmpt, $path, $is_required) = @_;
    my $rpath = !$path ? "(object)" : $path;
    my $ppref = $path  ? "$path/"   : "";
    my $r     = '';
    if ($schmpt->{default}) {
        my $val = _quote_var($schmpt->{default});
        $r = "  $sympt = $val if not defined $sympt;\n";
    }
    $r .= "if('HASH' eq ref($sympt)) {\n";
    if ($schmpt->{properties} && 'HASH' eq ref $schmpt->{properties}) {
        my %required;
        if ($schmpt->{required} && 'ARRAY' eq ref $schmpt->{required}) {
            %required = map {$_ => 1} @{$schmpt->{required}};
        }
        for my $k (keys %{$schmpt->{properties}}) {
            my $type = 'string';
            if ('HASH' eq ref $schmpt->{properties}{$k}) {
                $type = $schmpt->{properties}{$k}{type} // _guess_schema_type($schmpt->{properties}{$k});
            }
            my $val_func = "_validate_$type";
            my $qk       = _quote_var($k);
            $r .= $self->$val_func("${sympt}->{$qk}", $schmpt->{properties}{$k}, "$ppref$k", $required{$k});
        }
    }
    if (defined $schmpt->{minProperties}) {
        $schmpt->{minProperties} += 0;
        $r .= "  push \@\$errors, '$rpath must contain not less than $schmpt->{minProperties} properties'";
        $r .= " if keys %{$sympt} < $schmpt->{minProperties};\n";
    }
    if (defined $schmpt->{maxProperties}) {
        $schmpt->{maxProperties} += 0;
        $r .= "  push \@\$errors, '$rpath must contain not more than $schmpt->{maxProperties} properties'";
        $r .= " if keys %{$sympt} > $schmpt->{minProperties};\n";
    }
    my @pt;
    if (defined $schmpt->{patternProperties}) {
        for my $pt (keys %{$schmpt->{patternProperties}}) {
            my $type;
            $type = $schmpt->{patternProperties}{$pt}{type} // _guess_schema_type($schmpt->{patternProperties}{$pt});
            my $val_func = "_validate_$type";
            (my $upt = $pt) =~ s/"/\\"/g;
            $upt =~ s/\\Q(.*?)\\E/quotemeta($1)/eg;
            $upt =~ s/\\Q(.*)$/quotemeta($1)/eg;
            $upt =~ s|/|\\/|g;
            push @pt, $upt;
            my $ivf = $self->$val_func("\$_[0]", $schmpt->{patternProperties}{$pt}, "\$_[1]", "required");
            $r .= "  { my \@props = grep {/$upt/} keys %{${sympt}};";

            if ($schmpt->{properties} && 'HASH' eq ref $schmpt->{properties}) {
                my %apr = map {_quote_var($_) => undef} keys %{$schmpt->{properties}};
                $r .= "    my %defined_props = (" . join(", ", map {$_ => "undef"} keys %apr) . ");\n";
                $r .= "    \@props = grep {!exists \$defined_props{\$_} } \@props;\n";
            }
            $r .= "    my \$tf = sub { $ivf };\n";
            $r .= "    for my \$prop (\@props) {\n";
            $r .= "      \$tf->(${sympt}->{\$prop}, \"$ppref\${prop}\");\n";
            $r .= "    };\n";
            $r .= "  }\n";
        }
    }
    if (defined $schmpt->{additionalProperties}) {
        if (!ref($schmpt->{additionalProperties}) && !$schmpt->{additionalProperties}) {
            my %apr;
            $r .= "  {\n";
            if ($schmpt->{properties} && 'HASH' eq ref $schmpt->{properties}) {
                %apr = map {_quote_var($_) => undef} keys %{$schmpt->{properties}};
                $r .= "    my %allowed_props = (" . join(", ", map {$_ => "undef"} keys %apr) . ");\n";
                $r .= "    my \@unallowed_props = grep {!exists \$allowed_props{\$_} } keys %{${sympt}};\n";
                if (@pt) {
                    $r .= "    \@unallowed_props = grep { " . join("&&", map {"!/$_/"} @pt) . " } \@unallowed_props;\n";
                }
                $r .= "    push \@\$errors, \"$rpath contains not allowed properties: \@unallowed_props\" ";
                $r .= " if \@unallowed_props;\n";
            } else {
                $r .= "    push \@\$errors, \"$rpath can't contain properties\" if %{${sympt}};\n";
            }
            $r .= "  }\n";
        }
    }
    my $make_schemas_array = sub {
        my ($schemas) = @_;
        my @tfa;
        for my $schm (@{$schemas}) {
            my $type = $schm->{type} // _guess_schema_type($schm);
            my $val_func = "_validate_$type";
            my $ivf = $self->$val_func("\$_[0]", $schm, "$rpath", "required");
            push @tfa, "  sub {my \$errors = []; $ivf; \@\$errors == 0}\n";
        }
        return "(" . join(",\n", @tfa) . ")";
    };
    for my $fs (qw(anyOf allOf oneOf not)) {
        if (defined $schmpt->{fs} and 'HASH' eq ref $schmpt->{fs}) {
            $schmpt->{fs} = [$schmpt->{fs}];
        }
    }
    if (defined $schmpt->{anyOf} and 'ARRAY' eq ref $schmpt->{anyOf}) {
        $self->{required_modules}{'List::Util'}{none} = 1;
        $r .= "  {  my \@anyOf = " . $make_schemas_array->($schmpt->{anyOf}) . ";\n";
        $r
            .= "    push \@\$errors, \"$rpath doesn't match any required schema\" if none { \$_->(${sympt}, \"$rpath\") } \@anyOf;";
        $r .= "  }\n";
    }
    if (defined $schmpt->{allOf} and 'ARRAY' eq ref $schmpt->{allOf}) {
        $self->{required_modules}{'List::Util'}{notall} = 1;
        $r .= "  {  my \@allOf = " . $make_schemas_array->($schmpt->{allOf}) . ";\n";
        $r
            .= "    push \@\$errors, \"$rpath doesn't match all required schemas\" if notall { \$_->(${sympt}, \"$rpath\") } \@allOf;";
        $r .= "  }\n";
    }
    if (defined $schmpt->{oneOf} and 'ARRAY' eq ref $schmpt->{oneOf}) {
        $r .= "  {  my \@oneOf = " . $make_schemas_array->($schmpt->{oneOf}) . ";\n";
        $r .= "    my \$m = 0; for my \$t (\@oneOf) { ++\$m if \$t->(${sympt}, \"$rpath\"); last if \$m > 1; }";
        $r .= "    push \@\$errors, \"$rpath doesn't match exactly one required schema\" if \$m != 1;";
        $r .= "  }\n";
    }
    if (defined $schmpt->{not} and 'ARRAY' eq ref $schmpt->{not}) {
        $self->{required_modules}{'List::Util'}{any} = 1;
        $r .= "  {  my \@notOf = " . $make_schemas_array->($schmpt->{not}) . ";\n";
        $r .= "    push \@\$errors, \"$rpath matches a schema when must not\" if any { \$_->(${sympt}, \"$rpath\") } \@notOf;";
        $r .= "  }\n";
    }
    $r .= "}\n";
    if ($is_required) {
        $r .= "else {\n";
        $r .= "  push \@\$errors, \"$rpath is required\";\n";
        $r .= "}\n";
    }
    return $r;
}

sub _validate_array {
    my ($self, $sympt, $schmpt, $path, $is_required) = @_;
    my $rpath = !$path ? "(object)" : $path;
    my $r = '';
    if ($schmpt->{default}) {
        my $val = _quote_var($schmpt->{default});
        $r = "  $sympt = $val if not defined $sympt;\n";
    }
    $r .= "if('ARRAY' eq ref($sympt)) {\n";
    if (defined $schmpt->{minItems}) {
        $r .= "  push \@\$errors, '$path must contain not less than $schmpt->{minItems} items'";
        $r .= " if \@{$sympt} < $schmpt->{minItems};\n";
    }
    if (defined $schmpt->{maxItems}) {
        $r .= "  push \@\$errors, '$path must contain not more than $schmpt->{maxItems} items'";
        $r .= " if \@{$sympt} > $schmpt->{maxItems};\n";
    }
    if (defined $schmpt->{uniqueItems}) {
        $r .= "  { my %seen;\n";
        $r .= "    for (\@{$sympt}) {\n";
        $r .= "      if(\$seen{\$_}) { push \@\$errors, '$path must contain only unique items'; last }\n";
        $r .= "      \$seen{\$_} = 1;\n";
        $r .= "    };\n";
        $r .= "  }\n";
    }
    if ($schmpt->{items}) {
        my $type     = $schmpt->{items}{type} // _guess_schema_type($schmpt->{items});
        my $val_func = "_validate_$type";
        my $ivf      = $self->$val_func("\$_[0]", $schmpt->{items}, "$path/[]", $is_required);
        $r .= "  { my \$tf = sub { $ivf };\n";
        $r .= "    \$tf->(\$_, \"$rpath\") for (\@{$sympt});\n";
        $r .= "  }\n";
    }
    $r .= "}\n";
    if ($is_required) {
        $path = "array" if $path eq "";
        $r .= "else {\n";
        $r .= "  push \@\$errors, \"$path is required\";\n";
        $r .= "}\n";
    }
    return $r;
}

1;
