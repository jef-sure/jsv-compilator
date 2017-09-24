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
	$type = $schema->{type} // 'string';
	my $is_required = $opts{is_required} // $type eq 'object' || 0;
	my $val_func    = "_validate_$type";
	my $val_expr    = $self->$val_func($input_sym, $schema, $is_required);
	return "sub { $val_expr }";
}

# type: six primitive types ("null", "boolean", "object", "array", "number", or "string"), or "integer"

sub _sympt_to_path {
	my ($sympt) = @_;
	$sympt =~ s!^[^\{\}]+!/!;
	$sympt =~ s![\{\}]+!/!g;
	$sympt;
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
	my ($self, $sympt, $schmpt) = @_;
	return " !defined($sympt) ";
}

sub _validate_boolean {
	my ($self, $sympt, $schmpt, $is_required) = @_;
	my $r = '1 == 1';
	if (defined $schmpt->{default}) {
		my $val = _quote_var($schmpt->{default});
		$r = " do { $sympt =  $val if not defined $sympt; 1 } ";
	}
	if ($is_required) {
		$r = " defined($sympt) && ($r) ";
	} else {
		$r = " !defined($sympt) || defined($sympt) && ($r) ";
	}
	if (defined $schmpt->{const}) {
		$r = " $r && $r == $schmpt->{const} ";
	}
	if ($self->{to_json}) {
		$r = " $r && (($sympt)? \\1: \\0) ";
	} else {
		$r = " $r && $sympt ";
	}
	return "($r)";
}

sub _validate_string {
	my ($self, $sympt, $schmpt, $is_required) = @_;
	my $r = '1 == 1';
	if (defined $schmpt->{default}) {
		my $val = _quote_var($schmpt->{default});
		$r = " do { $sympt =  $val if not defined $sympt; 1 } ";
	}
	if (defined $schmpt->{maxLength}) {
		$r = " $r && length($sympt) <= $schmpt->{maxLength} ";
	}
	if (defined $schmpt->{minLength}) {
		$r = " $r && length($sympt) >= $schmpt->{minLength} ";
	}
	if (defined $schmpt->{const}) {
		my $val = _quote_var($schmpt->{const});
		$r = " $r && $r eq $val ";
	}
	if (defined $schmpt->{pattern}) {
		my $pattern = $schmpt->{pattern};
		$pattern =~ s/\\Q(.*?)(?:\\E|$)/quotemeta($1)/ge;
		$r = " $r && $r =~ /$pattern/ ";
	}
	if ($schmpt->{enum} && 'ARRAY' eq ref($schmpt->{enum}) && @{$schmpt->{enum}}) {
		my $can_list = join ", ", map {_quote_var($_)} @{$schmpt->{enum}};
		$self->{required_modules}{'List::Util'}{any} = 1;
		$r = " $r && (any {$_ eq $sympt} ($can_list)) ";
	}
	if ($schmpt->{format} && $formats{$schmpt->{format}}) {
		$r = " $r && ($sympt =~ /^$formats{$schmpt->{format}}\$/) ";
	}
	if ($self->{to_json} || $self->{coersion}) {
		$r = " $r && $sympt . \"\" eq $sympt ";
	}
	if ($is_required) {
		$r = " (defined($sympt) && ($r)) ";
	} else {
		$r = " (!defined($sympt) || (defined($sympt) && ($r))) ";
	}
	return $r;
}

sub _validate_any_number {
	my ($self, $sympt, $schmpt, $is_required, $re) = @_;
	my $r = '1 == 1';
	if (defined $schmpt->{default}) {
		my $val = _quote_var($schmpt->{default});
		$r = " do { $sympt =  $val if not defined $sympt; 1 } ";
	}
	$r = " $r && ($sympt =~ /^$re\$/) ";
	if (defined $schmpt->{minimum}) {
		$r = " $r &&  $sympt >= $schmpt->{minimum} ";
	}
	if (defined $schmpt->{maximum}) {
		$r = " $r &&  $sympt <= $schmpt->{maximum} ";
	}
	if (defined $schmpt->{exclusiveMinimum}) {
		$r = " $r &&  $sympt > $schmpt->{exclusiveMinimum} ";
	}
	if (defined $schmpt->{exclusiveMaximum}) {
		$r = " $r &&  $sympt < $schmpt->{exclusiveMaximum} ";
	}
	if (defined $schmpt->{const}) {
		$r = " $r && $r == $schmpt->{const} ";
	}
	if ($schmpt->{multipleOf}) {
		$self->{required_modules}{'POSIX'}{floor} = 1;
		$r = " $r &&  $sympt / $schmpt->{multipleOf} ==  floor($sympt / $schmpt->{multipleOf}) ";
	}
	if ($schmpt->{enum} && 'ARRAY' eq ref($schmpt->{enum}) && @{$schmpt->{enum}}) {
		my $can_list = join ", ", @{$schmpt->{enum}};
		$self->{required_modules}{'List::Util'}{any} = 1;
		$r = " $r && (any {$_ == $sympt} ($can_list)) ";
	}
	if ($schmpt->{format} && $formats{$schmpt->{format}}) {
		$r = " $r && ($sympt =~ /^$formats{$schmpt->{format}}\$/) ";
	}
	if ($self->{to_json} || $self->{coersion}) {
		$r = " $r && 0 + $sympt == $sympt ";
	}
	if ($is_required) {
		$r = " (defined($sympt) && ($r)) ";
	} else {
		$r = " (!defined($sympt) || (defined($sympt) && ($r))) ";
	}
	return $r;

}

sub _validate_number {
	my ($self, $sympt, $schmpt, $is_required) = @_;
	return $self->_validate_any_number($sympt, $schmpt, $is_required, $RE{num}{real});
}

sub _validate_integer {
	my ($self, $sympt, $schmpt, $is_required) = @_;
	return $self->_validate_any_number($sympt, $schmpt, $is_required, $RE{num}{int});
}

sub _validate_object {
	my ($self, $sympt, $schmpt, $is_required) = @_;
	my $r = '1 == 1';
	if ($schmpt->{default}) {
		my $val = _quote_var($schmpt->{default});
		$r = " do { $sympt =  $val if not defined $sympt; 1 } ";
	}
	$r = " $r && 'HASH' eq ref($sympt) ";
	if ($schmpt->{properties} && 'HASH' eq ref $schmpt->{properties}) {
		my %required;
		if ($schmpt->{required} && 'ARRAY' eq ref $schmpt->{required}) {
			%required = map {$_ => undef} @{$schmpt->{required}};
		}
		my @r;
		for my $k (keys %{$schmpt->{properties}}) {
			my $type = 'string';
			if ('HASH' eq ref $schmpt->{properties}{$k}) {
				$type = $schmpt->{properties}{$k}{type} // 'string';
			}
			my $val_func = "_validate_$type";
			push @r, $self->$val_func("${sympt}->{$k}", $schmpt->{properties}{$k}, $required{$k}) . "\n";
		}
		$r = join " && ", $r, @r;
	}
	if ($is_required) {
		$r = " (defined($sympt) && ($r)) ";
	} else {
		$r = " (!defined($sympt) || (defined($sympt) && ($r))) ";
	}
}

1;
