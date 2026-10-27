package DebmirrorUA;
# USTC answers 403 to the default "libwww-perl/x" User-Agent. Identify as debmirror
# instead (loaded through PERL5OPT=-MDebmirrorUA by debmirror-sync.sh).
use strict;
use warnings;
use LWP::UserAgent;
{
	no warnings 'redefine';
	*LWP::UserAgent::_agent = sub { "debmirror/2.37 (hub.ncosbit.net intranet mirror)" };
}
1;
