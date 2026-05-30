#!/usr/bin/env bash
# Fast srcline-resolving alternative to
#   `perf script -F +srcline --full-source-path | stackcollapse-perf.pl --srcline`.
#
# Runs `perf script` without srcline, then resolves frame addresses by invoking
# `addr2line` directly per DSO. In some Emacs tests this was ~100x faster than
# perf's built-in srcline path; results will vary with workload and binary.
#
# Usage:
#   perf-fold.sh PERF.DATA > out.folded
#
# Per-DSO load-base calibration: for each DSO that appears in samples, the first
# frame whose symbol we can find via `nm` gives us load_base = runtime_addr -
# nm_offset - sub_offset. Works uniformly for PIE and non-PIE binaries without
# having to detect ELF type.
#
# Caveats:
#
#   - Stripped binaries (e.g. libc.so.6 on stock distros) fall through to bare
#     function names — `nm` returns nothing, so calibration is skipped for
#     those DSOs. The function names are still present (perf carries them in
#     the recording) but :file:line is absent. `perf script -F +srcline`
#     finds these by consulting /usr/lib/debug/.build-id/XX/YYY.debug via
#     the binary's build-id; teaching this script to do the same is the
#     obvious next improvement.
#
#   - Inline expansion is more verbose than perf's: addr2line -i is run for
#     every address and each inline level becomes its own frame in the
#     output. `perf script -F +srcline` instead emits one frame per address
#     with the leaf inline's srcline appended to perf's outer function name.
#     Both convey the same information; flame graphs from this tool will be
#     deeper at inlined hotspots.
#
#   - addr2line's "??:?" placeholder for fully-unknown source locations is
#     passed through unchanged; perf normalizes it to "??:0". Cosmetic.
#
# Tested with:
#   - PIE and non-PIE Emacs builds
#   - frame-pointer and DWARF-unwound recordings

set -euo pipefail

DATA=${1:?Usage: $0 PERF.DATA}
TMP=$(mktemp -d -t perf-fold.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# 1. Bare perf script output (cheap — < 1s for a multi-MB perf.data).
perf script --max-stack 512 -i "$DATA" 2>/dev/null > "$TMP/raw.txt"

# 2-5. The rest is one self-contained perl pass.
perl - "$TMP" "$TMP/raw.txt" <<'PERL'
use strict;
use warnings;

my ($tmp, $raw) = @ARGV;

# ---------- 2. First pass: pick one calibration frame per DSO ----------
my %calibrate;     # dso -> [runtime_addr_hex, symbol, sub_offset_hex]
my %dso_addrs;     # dso -> { runtime_addr_hex => 1 } (collected upfront)
my %dso_seen_order;
my $dso_order = 0;

open my $in, "<", $raw or die "open $raw: $!";
while (<$in>) {
    next unless /^[ \t]+([0-9a-f]+) (\S+) \(([^)]+)\)$/;
    my ($addr_hex, $sym_off, $dso) = ($1, $2, $3);
    $dso_addrs{$dso}{$addr_hex} = 1;
    unless (exists $calibrate{$dso}) {
        my ($sym, $sub) = $sym_off =~ /^(.*?)\+(0x[0-9a-f]+)$/;
        if (defined $sym && $sym ne '[unknown]') {
            $calibrate{$dso} = [$addr_hex, $sym, $sub];
            $dso_seen_order{$dso} = $dso_order++;
        }
    }
}
close $in;

# ---------- 3. For each DSO, derive load_base via nm ----------
my %load_base;     # dso -> integer
for my $dso (sort { $dso_seen_order{$a} <=> $dso_seen_order{$b} } keys %calibrate) {
    next unless $dso =~ m{^/} && -r $dso;
    my ($addr_hex, $sym, $sub_off_hex) = @{$calibrate{$dso}};
    # nm output: "OFFSET TYPE SYMBOL". Stripped libs produce no output.
    open my $nm, "-|", "nm", $dso or do { warn "nm $dso: $!"; next };
    my $sym_off_hex;
    while (<$nm>) {
        if (/^([0-9a-f]+) \S \Q$sym\E$/) { $sym_off_hex = $1; last }
    }
    close $nm;
    next unless defined $sym_off_hex;
    $load_base{$dso} = hex($addr_hex) - hex($sym_off_hex) - hex($sub_off_hex);
}

# ---------- 4. Resolve all addresses per DSO via addr2line ----------
my %chain;        # "dso|addr_hex" -> "outer:f:l;...;leaf:f:l"
for my $dso (keys %load_base) {
    my $lb = $load_base{$dso};
    my @runtime_hexes = sort keys %{$dso_addrs{$dso}};
    next unless @runtime_hexes;

    # Compute binary addresses, preserving the order so we can match them back.
    my @bin_hexes = map { sprintf "%x", hex($_) - $lb } @runtime_hexes;
    my $addr_file = "$tmp/addrs";
    open my $af, ">", $addr_file or die "write $addr_file: $!";
    print $af "$_\n" for @bin_hexes;
    close $af;

    open my $a2l, "-|", "sh", "-c",
        qq{exec addr2line -e "\$1" -i -f -p < "\$2" 2>/dev/null},
        "sh", $dso, $addr_file
        or die "addr2line $dso: $!";

    my $cur = -1;
    my $built = '';
    while (my $line = <$a2l>) {
        chomp $line;
        if ($line =~ /^ \(inlined by\) (.*)$/) {
            $built = clean($1) . ";" . $built;
        } else {
            if ($cur >= 0) {
                $chain{"$dso|$runtime_hexes[$cur]"} = $built;
            }
            $cur++;
            $built = clean($line);
        }
    }
    if ($cur >= 0) {
        $chain{"$dso|$runtime_hexes[$cur]"} = $built;
    }
    close $a2l;
}

sub clean {
    my ($s) = @_;
    $s =~ s/ \(discriminator \d+\)$//;
    if ($s =~ /^(.+?) at (.+)$/) { return "$1:$2" }
    return $s;
}

# ---------- 5. Fold pass ----------
my %folded;
my ($comm, $stk, $weight) = ('', '', 0);

sub flush {
    if ($stk ne '') { $folded{"$comm;$stk"} += $weight }
    $stk = '';
    $weight = 0;
}

open $in, "<", $raw or die "open $raw: $!";
while (<$in>) {
    if (/^[^ \t]/) {
        # Sample header. The 4th whitespace-separated token is the event weight
        # for cycles-style profiles (e.g. "emacs-pie-fp 1464517 1866410.835154:    9091373 cycles:P:").
        flush();
        my @f = split;
        $comm = $f[0];
        $weight = (defined $f[3] && $f[3] =~ /^\d+$/) ? $f[3] + 0 : 1;
        next;
    }
    if (/^[ \t]*$/) { flush(); next }
    # Frame line.
    if (/^[ \t]+([0-9a-f]+) (\S+) \(([^)]+)\)/) {
        my ($addr_hex, $sym_off, $dso) = ($1, $2, $3);
        my $key = "$dso|$addr_hex";
        my $frame;
        if (exists $chain{$key}) {
            $frame = $chain{$key};
        } else {
            ($frame = $sym_off) =~ s/\+0x[0-9a-f]+.*$//;
        }
        $stk = $stk eq '' ? $frame : "$frame;$stk";
    }
}
flush();
close $in;

for my $k (sort keys %folded) {
    print "$k $folded{$k}\n";
}
PERL
