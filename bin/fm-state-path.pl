#!/usr/bin/env perl
# Guarded transition state operations; called through fm_state_path in fm-wake-lib.sh.
# Usage: fm-state-path.pl HOME STATE OP PATH [identity]
# STATE is the configured trust root, independent of HOME containment. Open the
# selected directory without following its leaf and match its resolved inode.
# Caller PID is captured before forking and supplied to create/claim/rollback.
# Files: check/read/snapshot PATH; replace/append PATH read stdin; clear PATH
# SNAPSHOT matches device/inode/SHA-256. snapshot prints that identity then bytes.
# Locks: owner-create LOCK PID; owner-delete OWNER [PID]; lock-link LOCK OWNER PID;
# lock-check/lock-pid/lock-unlink/lock-remove LOCK [OWNER [PID]].
# lock-link verifies the published claim in the same pinned operation and prints
# collision when the lock already exists; lock-pid returns a PID only after the
# complete owner and final link recheck.
# lock-identity is v1, canonical home, canonical lock, device:inode, one per line.
# Pin owned directories with no-follow opens and fchdir; regular files must have
# one link and the current UID. Reads and truncation use the verified descriptor.
# Atomic publication uses an exclusive private temporary in the pinned parent;
# rename/unlink never follow a substituted leaf. Queue clearing additionally
# matches the snapshot inode and digest after canonical admission.
# Generated queue owners record home, exact lock path and directory device/inode
# in lock-identity for every harness. Unknown/legacy queue owners are never
# inferred from PID alone.
# Every refusal warns and exits 1; callers preserve input and allow unknown arms.
use strict;
use warnings;
use Fcntl qw(:DEFAULT :mode);
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempfile tempdir);

my ($home, $state, $op, $path, @args) = @ARGV;
sub refuse { die "watcher: WARNING - unverified state path ($op): $_[0]\n" }
my $home_real = abs_path($home) // refuse('home unavailable');
my $state_real = abs_path($state) // refuse('state unavailable');
my @dirs;
sub pin_dir {
    my ($name) = @_;
    sysopen(my $d, $name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or refuse('directory unavailable');
    my @s = stat($d);
    S_ISDIR($s[2]) && $s[4] == $> or refuse('directory is not owned');
    chdir($d) or refuse('cannot pin directory');
    push @dirs, $d;
    return $d;
}
sub components {
    my ($rel) = @_;
    my @p = split m{/}, $rel, -1;
    @p && !grep { $_ eq '' || $_ eq '.' || $_ eq '..' } @p or refuse('invalid relative path');
    return @p;
}
my @selected = lstat($state_real);
my $state_dir = pin_dir($state);
my @pinned = stat($state_dir);
@selected && $selected[0] == $pinned[0] && $selected[1] == $pinned[1] or refuse('state identity changed');
sub parent {
    my ($p) = @_;
    index($p, "$state/") == 0 or refuse('path is outside selected state');
    chdir($state_dir) or refuse('state unavailable');
    my @p = components(substr($p, length($state) + 1));
    my $leaf = pop @p;
    pin_dir($_) for @p;
    return $leaf;
}
sub regular {
    my ($leaf, $create) = @_;
    my @s = lstat($leaf);
    if (!@s) {
        return undef unless $create;
        sysopen(my $f, $leaf, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or refuse('exclusive creation failed');
        return $f;
    }
    S_ISREG($s[2]) && $s[4] == $> && $s[3] == 1 or refuse('not a private regular file');
    sysopen(my $f, $leaf, O_RDWR | O_NOFOLLOW | O_NONBLOCK) or refuse('no-follow open failed');
    my @f = stat($f);
    $f[0] == $s[0] && $f[1] == $s[1] && S_ISREG($f[2]) && $f[4] == $> && $f[3] == 1 or refuse('file identity changed');
    return $f;
}
sub contents {
    my ($f) = @_;
    return '' unless $f;
    seek($f, 0, 0) or refuse('seek failed');
    local $/;
    local $! = 0;
    my $bytes = <$f>;
    defined($bytes) || !$! or refuse('read failed');
    return $bytes // '';
}
sub identity {
    my ($f) = @_;
    return 'missing' unless $f;
    my @s = stat($f);
    return join(':', @s[0,1], sha256_hex(contents($f)));
}
sub same_leaf {
    my ($leaf, $f) = @_;
    my @s = lstat($leaf);
    return !@s unless $f;
    my @f = stat($f);
    return @s && S_ISREG($s[2]) && $s[0] == $f[0] && $s[1] == $f[1] && $s[3] == 1 && $s[4] == $>;
}
sub write_file {
    my ($f, $bytes) = @_;
    truncate($f, 0) && seek($f, 0, 0) or refuse('truncate failed');
    print {$f} $bytes or refuse('write failed');
    close($f) or refuse('close failed');
}
sub owner {
    my ($p) = @_;
    my $leaf = parent($p);
    my $owner_parent = $dirs[-1];
    $leaf =~ /\A(.+)\.owner\.[A-Za-z0-9_]{6}\z/ or refuse('not a generated owner');
    my $lock = $p;
    $lock =~ s/\.owner\.[A-Za-z0-9_]{6}\z//;
    my $lock_real = $state_real . substr($lock, length($state));
    my $d = pin_dir($leaf);
    my @s = stat($d);
    my $id = regular('lock-identity', 0) // refuse('owner identity missing');
    contents($id) eq "v1\n$home_real\n$lock_real\n$s[0]:$s[1]\n" or refuse('owner identity mismatch');
    return ($leaf, $lock, $d, $owner_parent);
}
sub owner_files {
    my @names = qw(pid fm-home pid-identity role watcher-path lock-identity);
    my @files = map { [$_, regular($_, 0)] } @names;
    for my $entry (@files) {
        my ($name, $f) = @$entry;
        next unless $f;
        same_leaf($name, $f) or refuse('owner child changed');
    }
    return @files;
}
sub remove_owner_files {
    for my $entry (@_) {
        my ($name, $f) = @$entry;
        next unless $f;
        same_leaf($name, $f) or refuse('owner child changed');
        unlink($name) or refuse('owner cleanup failed');
    }
}

if ($op eq 'owner-create') {
    my $lock = parent($path);
    my $dir = tempdir("$lock.owner.XXXXXX", DIR => '.', CLEANUP => 0);
    $dir =~ s{\A\./}{};
    my $d = pin_dir($dir);
    my @s = stat($d);
    my $lock_real = $state_real . substr($path, length($state));
    write_file(regular('lock-identity', 1), "v1\n$home_real\n$lock_real\n$s[0]:$s[1]\n");
    write_file(regular('pid', 1), "$args[0]\n");
    my $owner_parent = $path;
    $owner_parent =~ s{/[^/]+\z}{};
    print "$owner_parent/$dir\n";
} elsif ($op eq 'owner-delete') {
    my ($leaf, $lock, $d, $owner_parent) = owner($path);
    my $pid = contents(regular('pid', 0)); chomp $pid;
    !@args || $pid eq $args[0] or refuse('owner PID changed');
    my @files = owner_files();
    remove_owner_files(@files);
    chdir($owner_parent) or refuse('owner parent unavailable');
    my @a = lstat($leaf); my @b = stat($d);
    @a && S_ISDIR($a[2]) && $a[0] == $b[0] && $a[1] == $b[1] or refuse('owner directory changed');
    rmdir($leaf) or refuse('owner directory is not empty');
} elsif ($op =~ /\Alock-(?:link|check|pid|unlink|remove)\z/) {
    my $lock = parent($path);
    my $link_parent = $dirs[-1];
    my $target = $op eq 'lock-link' ? $args[0] : readlink($lock);
    defined($target) or refuse('lock is not a generated link');
    !@args || $args[0] eq '' || $target eq $args[0] or refuse('lock target changed');
    my ($leaf, $recorded_lock, $d) = owner($target);
    $recorded_lock eq $path or refuse('owner belongs to another lock');
    my $pid = contents(regular('pid', 0)); chomp $pid;
    $pid =~ /\A[0-9]+\z/ or refuse('owner PID unavailable');
    !defined($args[1]) || $args[1] eq '' || $pid eq $args[1] or refuse('owner PID changed');
    my @files = ($op ne 'lock-link') ? owner_files() : ();
    chdir($link_parent) or refuse('lock parent unavailable');
    if ($op eq 'lock-link') {
        symlink($target, $lock) or do { print "collision\n" if $!{EEXIST}; exit 1 };
        my ($claimed_leaf, $claimed_lock, $claimed_dir) = owner($target);
        $claimed_lock eq $path or refuse('owner belongs to another lock');
        my $claimed_pid = contents(regular('pid', 0)); chomp $claimed_pid;
        $claimed_pid eq $args[1] or refuse('owner PID changed');
        owner_files();
        chdir($link_parent) or refuse('lock parent unavailable');
        (readlink($lock) // '') eq $target or refuse('lock link changed');
    } else {
        (readlink($lock) // '') eq $target or refuse('lock link changed');
        if ($op eq 'lock-unlink' || $op eq 'lock-remove') {
            unlink($lock) or refuse('lock unlink failed');
        }
    }
    if ($op eq 'lock-pid') { print "$pid\n"; exit 0 }
    if ($op eq 'lock-remove') {
        chdir($d) or refuse('owner unavailable');
        remove_owner_files(@files);
        chdir($link_parent) or refuse('lock parent unavailable');
        my @a = lstat($leaf); my @b = stat($d);
        @a && S_ISDIR($a[2]) && $a[0] == $b[0] && $a[1] == $b[1] or refuse('owner directory changed');
        rmdir($leaf) or refuse('owner directory is not empty');
    }
} else {
    my $leaf = parent($path);
    my $f = regular($leaf, 0);
    if ($op eq 'check') { exit 0 }
    if ($op eq 'snapshot') {
        print identity($f), "\n", contents($f);
    } elsif ($op eq 'read') {
        if ($f) {
            while (1) {
                my $n = read($f, my $buffer, 65536);
                defined($n) or refuse('read failed');
                last unless $n;
                print $buffer or refuse('read output failed');
            }
        }
    } elsif ($op eq 'clear') {
        identity($f) eq $args[0] or refuse('queue snapshot changed');
        $f //= regular($leaf, 1);
        same_leaf($leaf, $f) or refuse('queue path changed');
        write_file($f, '');
    } elsif ($op eq 'replace') {
        local $/; my $bytes = <STDIN> // '';
        my ($tmp, $name) = tempfile('.omp-state.XXXXXX', DIR => '.', UNLINK => 0);
        my @created = stat($tmp);
        my $ok = eval {
            print {$tmp} $bytes or refuse('temporary write failed');
            close($tmp) or refuse('temporary close failed');
            my $source = regular($name, 0) // refuse('temporary disappeared');
            my @source = stat($source);
            $source[0] == $created[0] && $source[1] == $created[1] or refuse('temporary identity changed');
            same_leaf($name, $source) or refuse('temporary path changed');
            same_leaf($leaf, $f) or refuse('destination changed');
            rename($name, $leaf) or refuse('publication failed');
            1;
        };
        my $error = $@;
        if (!$ok) {
            my @left = lstat($name);
            unlink($name) if @left && S_ISREG($left[2]) && $left[0] == $created[0] && $left[1] == $created[1];
            die $error;
        }
    } elsif ($op eq 'append') {
        $f //= regular($leaf, 1);
        same_leaf($leaf, $f) or refuse('append path changed');
        seek($f, 0, 2) or refuse('append seek failed');
        local $/; print {$f} (<STDIN> // '') or refuse('append failed');
        close($f) or refuse('append close failed');
    } else { refuse('unknown operation') }
}
