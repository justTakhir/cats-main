package CATS::RouteParser;

use strict;
use warnings;

use Exporter qw(import);

use JSON::XS;

use CATS::Utils;

our @EXPORT = qw(
    array_of
    bool
    bool0
    clist_of
    encoding
    encoding_default
    fixed
    ident
    integer
    json
    problem_code
    required
    sha
    signed_integer
    str
    upload
);

sub bool() { qr/^1$/ }
sub bool0() { qr/^[01]$/ }
sub integer() { qr/^[0-9]+$/ } # 'int' is reserved.
sub signed_integer() { qr/^[+-]?[0-9]+$/ }
sub fixed() { qr/^[+-]?([0-9]*[.])?[0-9]+$/ }
sub sha() { qr/^[a-h0-9]+$/ }
sub str() { qr/./ }
sub ident() { qr/^[a-zA-Z][a-zA-Z_0-9]*$/ }
sub problem_code() { qr/^[A-Za-z0-9]{1,3}$/ }

sub check_encoding { $_[0] && CATS::Utils::encodings->{$_[0]} }
sub encoding() { \&check_encoding }
sub encoding_default($) {
    my ($default) = @_;
    sub { check_encoding($_[0]) ? $_[0] : ($_[0] = $default) };
}

sub upload() {{ upload => 1 }}
sub json() {{ json => 1 }}

BEGIN {
    for my $name (qw(array_of clist_of required)) {
        no strict 'refs';
        # Prototype to allow acting as a unary operator.
        *$name = sub($) {
            ref $_[0] eq 'HASH' or return { $name => 1, type => $_[0] };
            $_[0]->{$name} = 1;
            $_[0];
        };
    }
}

sub check_type { !defined $_[1] || $_[0] =~ $_[1] }

sub parse_route {
    my ($p, $route) = @_;
    ref $route eq 'ARRAY' or return $route;
    my $fn = $route->[0];
    $p->{route} = $route;

    for (my $i = 1; $i < @$route; $i += 2) {
        my $name = $route->[$i];
        my $type = $route->[$i + 1];

        if (ref $type eq 'CODE') {
            my $value = $p->web_param($name);
            $p->{$name} = $value if $type->($value);
            next;
        }
        if (ref $type ne 'HASH') {
            my $value = $p->web_param($name);
            $p->{$name} = $value if defined $value && check_type($value, $type);
            next;
        }

        if ($type->{upload}) {
            $p->{$name} = $p->make_upload($name);
            next;
        }
        if ($type->{json}) {
            eval { $p->{$name} = JSON::XS::decode_json($p->web_param($name)); 1; };
            next;
        }
        if ($type->{array_of}) {
            my @values = grep check_type($_, $type->{type}), $p->web_param($name);
            return if !@values && $type->{required};
            $p->{$name} = \@values;
            next;
        }

        my $value = $p->web_param($name);
        if ($type->{clist_of}) {
            my @values = grep check_type($_, $type->{type}), split ',', $value // '';
            return if !@values && $type->{required};
            $p->{$name} = \@values;
            next;
        }

        if (!defined $value) {
            return if $type->{required};
            next;
        }

        if (check_type($value, $type->{type})) {
            $p->{$name} = $value;
        }
        elsif ($type->{required}) {
            return;
        }
    }

    $fn;
}

sub _reconstruct_one {
    my ($name, $value, $type) = @_;
    if (ref $type eq 'HASH') {
        $type->{upload} and die 'Unable to reconstruct upload';
        return
            $type->{array_of} ? map { $name => $_ } @$value :
            $type->{clist_of} ? (@$value ? ($name, join ',', @$value) : ()):
            ($name, $value);
    }
    return ($name, $value);
}

sub reconstruct {
    my ($p, %override) = @_;
    my @result = %override;
    my $route = $p->{route} or die;
    for (my $i = 1; $i < @$route; $i += 2) {
        my $name = $route->[$i];
        exists $p->{$name} && !exists $override{$name} or next;
        my $type = $route->[$i + 1];
        my $value = $p->{$name};
        push @result, _reconstruct_one($name, $value, $type);
    }
    @result;
}

1;
