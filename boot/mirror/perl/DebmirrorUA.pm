package DebmirrorUA;
# Loaded through PERL5OPT=-MDebmirrorUA by debmirror-sync.sh.
#  * USTC answers 403 to the default "libwww-perl/x" User-Agent: identify as debmirror.
#  * DEBMIRROR_BWLIMIT_KBPS=N (N > 0) caps the HTTP body download rate of this process at
#    N KiB/s. debmirror fetches files one after another, so this is the whole download rate.
#    (trickle/LD_PRELOAD does not throttle perl's sockets here; tc cannot shape one process.)
use strict;
use warnings;
use LWP::UserAgent;
use Net::HTTP;
use Time::HiRes qw(time sleep);

my $limit = ($ENV{DEBMIRROR_BWLIMIT_KBPS} // 0) * 1024;
my $next = 0;

{
	no warnings 'redefine';
	*LWP::UserAgent::_agent = sub { "debmirror/2.37 (hub.ncosbit.net intranet mirror)" };

	if ($limit > 0) {
		my $orig = \&Net::HTTP::Methods::read_entity_body;
		*Net::HTTP::Methods::read_entity_body = sub {
			my $n = $orig->(@_);
			if (defined $n && $n > 0) {
				my $now = time;
				$next = $now if $next < $now;
				$next += $n / $limit;
				my $wait = $next - $now;
				sleep($wait) if $wait > 0.002;
			}
			return $n;
		};
	}
}
1;
