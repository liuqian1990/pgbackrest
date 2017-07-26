####################################################################################################################################
# Config Tests
####################################################################################################################################
use strict;
use warnings;
use Carp;
use English '-no_match_vars';

use Fcntl qw(O_RDONLY);

# Set number of tests
use Test::More tests => 3;

# Load the module dynamically so it does not interfere with the test above
use pgBackRest::LibC qw(:config);

ok (optionGet('dude') eq 'FALSE');
ok (optionGet('dude', 0) eq 'FALSE');
ok (optionGet('dude', 1) eq 'TRUE');
