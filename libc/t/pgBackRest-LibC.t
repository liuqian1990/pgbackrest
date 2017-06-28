####################################################################################################################################
# pgBackRest-LibC.t - Unit tests for the LibC module
####################################################################################################################################
use strict;
use warnings;
use Carp;
use English '-no_match_vars';

use Config;
use Fcntl qw(O_RDONLY);

# Set number of tests
use Test::More tests => 11;

# Make sure the module loads without errors
BEGIN {use_ok('pgBackRest::LibC')};

# Load the module dynamically so it does not interfere with the test above
require pgBackRest::LibC;
pgBackRest::LibC->import(qw(:debug :checksum));

# UVSIZE determines the pointer and long long int size.  This needs to be 8 to indicate 64-bit types are available.
ok (&UVSIZE == 8, 'UVSIZE == 8');

# Is the architecture little or big-endian?
my $bLittleEndian = $Config{byteorder} eq '12345678' || $Config{byteorder} eq '1234' ? 1 :
    ($Config{byteorder} eq '87654321' || $Config{byteorder} eq '4321' ? 0 :
        confess 'unsupported architecture with byte order \'' . $Config{byteorder} . '\'');

sub pageBuild
{
    my $tPageSource = shift;
    my $iWalId = shift;
    my $iWalOffset = shift;
    my $iBlockNo = shift;

    my $tPage = pack('I', $iWalId) . pack('I', $iWalOffset) . substr($tPageSource, 8);
    my $iChecksum = pageChecksum($tPage, $iBlockNo, length($tPage));

    return substr($tPage, 0, 8) . pack('S', $iChecksum) . substr($tPage, 10);
}

# Test page-level checksums
{
    my $strPageFile = 't/data/page.bin';
    my $iPageSize = 8192;
    my $iPageChecksum = $bLittleEndian ? 0x1B99 : 0xA9C0;

    # Load the block into a buffer
    sysopen(my $hFile, $strPageFile, O_RDONLY)
        or confess "unable to open ${strPageFile}";

    sysread($hFile, my $tBuffer, $iPageSize) == $iPageSize
        or confess "unable to read 8192 bytes from ${strPageFile}";

    close ($hFile);

    # Test the checksum
    my $iPageChecksumTest = pageChecksum($tBuffer, 0, $iPageSize);

    ok (
        $iPageChecksumTest == $iPageChecksum,
        'page checksum test (' . sprintf('%X', $iPageChecksumTest) .
        ') == page checksum (' . sprintf('%X', $iPageChecksum) . ')');

    # Test the checksum on a different block no
    $iPageChecksumTest = pageChecksum($tBuffer, 1, $iPageSize);
    my $iPageChecksumBlockNo = $iPageChecksum + 1;

    ok (
        $iPageChecksumTest == $iPageChecksumBlockNo,
        'page checksum test (' . sprintf('%X', $iPageChecksumTest) .
        ') == page checksum blockno (' . sprintf('%X', $iPageChecksumBlockNo) . ')');

    # Now munge the block and make sure the checksum changes
    $iPageChecksumTest = pageChecksum(pack('I', 1024) . substr($tBuffer, 4), 0, $iPageSize);
    my $iPageChecksumMunge = $bLittleEndian ? 0xFCFF : 0x9D9E;

    ok (
        $iPageChecksumTest == $iPageChecksumMunge,
        'page checksum test (' . sprintf('%X', $iPageChecksumTest) .
        ') == page checksum munge (' . sprintf('%X', $iPageChecksumMunge) . ')');

    # Pass a valid page buffer
    my $tBufferMulti =
        $tBuffer .
        substr($tBuffer, 0, 8) . pack('S', $iPageChecksum + 1) . substr($tBuffer, 10) .
        substr($tBuffer, 0, 8) . pack('S', $iPageChecksum - 2) . substr($tBuffer, 10) .
        substr($tBuffer, 0, 8) . pack('S', $iPageChecksum - 1) . substr($tBuffer, 10) .
        substr($tBuffer, 0, 8) . pack('S', $iPageChecksum + 4) . substr($tBuffer, 10) .
        substr($tBuffer, 0, 8) . pack('S', $iPageChecksum + 5) . substr($tBuffer, 10) .
        substr($tBuffer, 0, 8) . pack('S', $iPageChecksum + 2) . substr($tBuffer, 10) .
        substr($tBuffer, 0, 8) . pack('S', $iPageChecksum + 3) . substr($tBuffer, 10);

    ok (pageChecksumBufferTest($tBufferMulti, length($tBufferMulti), 0, $iPageSize, 0xFFFF, 0xFFFF), 'pass valid page buffer');

    # Make sure that an invalid buffer size throws an exception
    eval
    {
        pageChecksumBufferTest($tBufferMulti, length($tBufferMulti) - 1, 0, $iPageSize, 0xFFFF, 0xFFFF);
    };

    ok (defined($EVAL_ERROR) && $EVAL_ERROR =~ 'buffer size 65535, page size 8192 are not divisible.*', 'invalid page buffer size');

    # Allow page with an invalid checksum because LSN >= ignore LSN
    $tBufferMulti =
        pageBuild($tBuffer, 0, 0, 0) .
        pageBuild($tBuffer, 0xFFFF, 0xFFFE, 0) .
        pageBuild($tBuffer, 0, 0, 2);

    ok (pageChecksumBufferTest($tBufferMulti, length($tBufferMulti), 0, $iPageSize, 0xFFFF, 0xFFFE), 'skip invalid checksum');

    # Reject an invalid page buffer (second block will error because the checksum will not contain the correct block no)
    ok (!pageChecksumBufferTest($tBufferMulti, length($tBufferMulti), 0, $iPageSize, 0xFFFF, 0xFFFF), 'reject invalid page buffer');

    # Find the rejected page in the buffer
    my $iRejectedBlockNo = -1;
    my $iExpectedBlockNo = 1;

    for (my $iIndex = 0; $iIndex < length($tBufferMulti) / $iPageSize; $iIndex++)
    {
        if (!pageChecksumTest(substr($tBufferMulti, $iIndex * $iPageSize, $iPageSize), $iIndex, $iPageSize, 0xFFFF, 0xFFFF))
        {
            $iRejectedBlockNo = $iIndex;
        }
    }

    ok ($iRejectedBlockNo == $iExpectedBlockNo, "rejected blockno ${iRejectedBlockNo} equals expected ${iExpectedBlockNo}");

    # Reject an misaligned page buffer
    $tBufferMulti =
        pageBuild($tBuffer, 0, 0, 0) .
        substr(pageBuild($tBuffer, 0, 0, 1), 1);

    eval
    {
        pageChecksumBufferTest($tBufferMulti, length($tBufferMulti), 0, $iPageSize, 0xFFFF, 0xFFFF);
        ok (0, 'misaligned test should have failed');
    }
    or do
    {
        ok (1, 'misaligned test failed');
    };
}
