#!/usr/bin/perl
# Generate api/openapi.yaml from Netdot's meta (the model is the single source
# of truth). Run it whenever the model / API surface changes:
#
#     perl -Ilib api/gen_openapi.pl
#
# The app serves the file at /api/openapi.yaml (and builds it on the fly from
# meta if the file is absent). Swagger UI: /api/docs.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Netdot;
use Netdot::Model;
use Netdot::Mojo::OpenAPI;
use YAML::XS;

my $spec = Netdot::Mojo::OpenAPI::build_spec();

# Output path: <project root>/api/openapi.yaml (project root from config, else
# the directory containing this script).
my $base = Netdot->config->get('NETDOT_PATH');
my $out  = ( $base && length $base ) ? "$base/api/openapi.yaml" : "$FindBin::Bin/openapi.yaml";

my $yaml = YAML::XS::Dump($spec);
open my $fh, '>:encoding(UTF-8)', $out
    or die "Cannot write $out: $!";
print $fh $yaml;
close $fh;

my $ntables = scalar keys %{ $spec->{components}{schemas} };
my $npaths  = scalar keys %{ $spec->{paths} };
printf "Wrote %s (%d tables, %d paths)\n", $out, $ntables, $npaths;
