#!/usr/bin/perl -w
#
# Facilitate dependencies installation

use strict;
use CPAN;

my $action = $ARGV[0] 
    or die "
Arguments:
	test              - Show list of installed and missing modules
	install           - Try to install missing modules using the CPAN
	apt-install       - Install using apt-get when possible
	rpm-install       - Install using rpm packages when possible
";

# DEPS is now a list of anonymous hashes with three keys 'cpan' 'apt' and 'rpm'.  
# Their contents should be fairly obvious, cpan is the name of the perl module in CPAN.  
# apt is the name or names (space delimited) of the perl module, 
# or perl modules that may be dependencies of the module in question
# if the module is not avaliable in the apt-get repository (installing dependencies 
# makes the cpan install process more reliable though).  rpm is the 
# same idea as apt, but refers to the module name in the rpm repository.

my @DEPS = (
    # --- Mojolicious web app (new web layer) ---
    {cpan=>'Mojolicious', apt=>'libmojolicious-perl', rpm=>'perl-Mojolicious'},
    {cpan=>'Crypt::URandom', apt=>'libcrypt-urandom-perl', rpm=>'perl-Crypt-URandom'},
    {cpan=>'JSON', apt=>'libjson-perl', rpm=>'perl-JSON-PP'},
    {cpan=>'Net::LDAP', apt=>'libnet-ldap-perl', rpm=>'perl-Net-LDAP'},
    {cpan=>'YAML::XS', apt=>'libyaml-libyaml-perl', rpm=>'perl-YAML-XS'},
    {apt=> 'rrdtool', rpm=>'rrdtool'},
    {cpan=>'RRDs' , apt=>'librrds-perl', rpm=>'rrdtool-perl'},
    {cpan=>'GraphViz', apt=> 'graphviz libgraphviz-perl', 
     rpm=>'graphviz graphviz-devel libpng-devel graphviz-gd perl-GraphViz'},
    {cpan=>'Module::Build' , apt=> 'libmodule-build-perl', rpm=>'perl-Module-Build'},
    {cpan=>'CGI' , apt=>'libcgi-pm-perl'},
    {cpan=>'Class::DBI', apt=> 'libclass-dbi-perl', rpm=>'perl-Class-DBI'},
    {cpan=>'Class::DBI::AbstractSearch', apt=>'libclass-dbi-abstractsearch-perl', 
     rpm=>'perl-Class-DBI-AbstractSearch'},
    {cpan=>'URI::Escape', apt=>'liburi-perl', rpm=>'perl-URI'},
    {cpan=>'SQL::Translator', apt=>'libsql-translator-perl', rpm=>'perl-SQL-Translator'},
    {cpan=>'SNMP::Info', apt=>'libsnmp-info-perl', rpm=>'perl-SNMP-Info'},
    {cpan=>'NetAddr::IP 4.042', apt=>'libnetaddr-ip-perl', rpm=>'perl-NetAddr-IP'},
    {cpan=>'Log::Dispatch', apt=>'liblog-dispatch-perl', rpm=>'perl-Log-Dispatch'},
    {cpan=>'Log::Log4perl', apt=>'liblog-log4perl-perl', rpm=>'perl-Log-Log4perl'},
    {cpan=>'Parallel::ForkManager', apt=>'libparallel-forkmanager-perl', 
     rpm=>'perl-Parallel-ForkManager'},
    {cpan=>'Net::Patricia 1.20', apt=> 'libnet-patricia-perl', rpm=>''},
    {cpan=>'Test::Simple' , apt=> 'libtest-simple-perl', rpm=>''},
    {cpan=>'Test::Exception' , apt=> 'libtest-exception-perl', rpm=>''},
    {cpan=>'Net::IRR', apt=> 'libnet-irr-perl', rpm=>''},
    {cpan=>'Time::Local', apt=> 'libtime-local-perl', rpm=>''},
    {cpan=>'File::Spec',apt=> 'libfile-spec-perl', rpm=>''},
    {cpan=>'Net::Appliance::Session',apt=> 'libnet-appliance-session-perl', rpm=>''},
    {cpan=>'BIND::Config::Parser', apt=>'libbind-config-parser-perl', rpm=>''},
    {cpan=>'Net::DNS', apt=> 'libnet-dns-perl', rpm=>'perl-Net-DNS'},
    {cpan=>'Text::ParseWords', apt=>'', rpm=>''},
    {cpan=>'Carp::Assert', apt=>'libcarp-assert-perl', rpm=>'perl-Carp-Assert'},
    {cpan=>'Digest::SHA', apt=> 'libdigest-sha-perl', rpm=>'perl-Digest-SHA1'},
    {apt=> 'libssl-dev', rpm=>'openssl-devel'}, # needed by Net::DNS::ZoneFile
    {cpan=>'Net::DNS::ZoneFile', apt=> 'libnet-dns-perl', rpm=>'perl-Net-DNS'},
    {cpan=>'Socket6', apt=> 'libsocket6-perl', rpm=>'perl-Socket6'},
    {cpan=>'XML::Simple', apt=>'libxml-simple-perl', rpm=>'perl-XML-Simple'},
    {apt=>'snmp'},
    {apt=> 'git', rpm=>'git'},   # fetches the netdisco MIBs (see apt-install)
    # --- runtime deps not provided by the packages above (audited against
    #     the `use` statements in lib/); listed explicitly so testdeps /
    #     apt-install cover them even when apt would only pull them in
    #     transitively. ---
    {cpan=>'Exception::Class', apt=>'libexception-class-perl', rpm=>'perl-Exception-Class'},
    {cpan=>'LWP::UserAgent', apt=>'libwww-perl', rpm=>'perl-libwww-perl'},
    {cpan=>'XML::LibXML', apt=>'libxml-libxml-perl', rpm=>'perl-XML-LibXML'},
    {cpan=>'AnyEvent', apt=>'libanyevent-perl', rpm=>'perl-AnyEvent'},
    {cpan=>'Coro', apt=>'libcoro-perl', rpm=>'perl-Coro'},
    {cpan=>'Date::Parse', apt=>'libtimedate-perl', rpm=>'perl-TimeDate'},
    # Data::Dump is used at runtime (DBUTIL, Netdot.pm, Model/Device,
    # Model/PhysAddr) but is only a Recommends of libwww-perl, so a
    # --no-install-recommends install misses it.
    {cpan=>'Data::Dump', apt=>'libdata-dump-perl', rpm=>'perl-Data-Dump'},
    ) ;

if ( $action eq 'test' ){
    &run_test();

}elsif ( $action eq 'install' || $action eq 'apt-install' || $action eq 'rpm-install'){

    # Needed for RPM installs
    my $epel_rel;
    my $installed_epel = 0;
    
    if ( $> != 0 ){
	die "You must be root to install required dependencies";
    }
    
    print "\nWhich RDBMS do you plan to use as backend: [mysql|Pg]? ";
    my $ans = <STDIN>;
    chomp($ans);
    if ( $ans =~ /mysql/i ){
	push (@DEPS, {apt=>'mariadb-server', rpm=>'mysql-server'});
	push (@DEPS, {cpan=>'DBD::mysql', apt=> 'libdbd-mysql-perl', rpm=>'perl-DBD-MySQL'});

    }elsif ( $ans =~ /pg/i ){
	push (@DEPS, {apt=>'postgresql', rpm=>'postgresql'});
	push (@DEPS, {cpan=>'DBD::Pg', apt=> 'libdbd-pg-perl', rpm=>'perl-DBD-Pg'});
    }else{
	die "Unrecognized RDBMS: $ans\n";
    }
    my $program;
    if( $action eq 'rpm-install' ){
	$program = 'yum install';
	# Check if RHEL
	my $rhel_chk = `lsb_release -i`;
	if ( $rhel_chk =~ /RedHatEnterpriseServer/ ){
	    my $epel_chk = `rpm -qs epel-release`;
	    unless ( $epel_chk =~ /^normal/ ){
		print 'Be aware that the official RHEL repositories do not include many of the packages '.
		    'that Netdot requires.  Would you like to use the EPEL (Extra Packages for '.
		    'Enterprise Linux) repository to help install these packages? [y/n] ';
		my $ans = <STDIN>;
		if ( $ans =~ /(Y|y)/ ){
		    my $rh_rel = `lsb_release -r -s`;
		    chomp($rh_rel);
		    # Grab the first digit only
		    $rh_rel = int($rh_rel);
		    
		    # Set the current version of EPEL for this release
		    # TODO: find a way to automate this!
		    if ( $rh_rel eq '5' ){
			$epel_rel = '5-4';
		    }elsif ( $rh_rel eq '6' ){
			$epel_rel = '6-8';
		    }else{
			die "Unknown release: $rh_rel\n";
		    }
		    my $cmd = "rpm -Uvh http://mirrors.kernel.org/fedora-epel/$rh_rel/i386/".
			"epel-release-$epel_rel.noarch.rpm";
		    
		    &cmd($cmd);
		    $installed_epel = 1;
		    
		    # Check if optional channel is installed
		    my $rhel_optional_chk = `yum repolist`;
		    unless ( $rhel_optional_chk =~ /RHEL Server Optional/m ){
			print "It looks like this is RedHat Enterprise Server, but you have not \n".
			    "enabled the Optional channel, which is needed to satisfy dependencies \n".
			    "in the EPEL repository. See instructions at: \n\n".
			    "    https://access.redhat.com/knowledge/solutions/11312\n\n";
		    }
		}
	    }
	}
    }elsif ( $action eq 'apt-install' ){
	$program = 'apt-get -y install';
	
	# Try to install as little as possible
	$program .= ' --no-install-recommends';

    }
    
    if ( $action eq 'apt-install' || $action eq 'rpm-install' ){
	my $argstr = " ";
	foreach my $anon_hash ( @DEPS ){
	    if ( $action eq 'apt-install' ){
		$argstr .= " ".$anon_hash->{'apt'} if exists $anon_hash->{'apt'};
	    }
	    else{
		$argstr .= " ".$anon_hash->{'rpm'} if exists $anon_hash->{'rpm'};
	    }
	}

	&cmd("$program $argstr");

    }elsif ( $action eq 'install' ){
	&install_modules_cpan();
    }

    if ( $installed_epel ){
	print "Would you like to uninstall EPEL at this time? [y/n] ";
	my $ans = <STDIN>;
	if ( $ans =~ /(Y|y)/ ){
	    &cmd("yum erase epel-release-$epel_rel.noarch");
	}
    }

    if ( $action eq 'apt-install' ){
	# Automate this part for the user too
	print "\nWe will install the SNMP MIB files now. Continue? [y/n] ";
	my $ans = <STDIN>;
	if ( $ans =~ /(Y|y)/ ){
	    # Clone the netdisco MIB collection (replaces the retired
	    # netdisco-mibs-installer download/install scripts).
	    print "Downloading the netdisco MIB files. This may take a few minutes.\n";
	    &cmd('rm -rf /tmp/netdisco-mibs');
	    &cmd('git clone --depth 1 https://github.com/netdisco/netdisco-mibs /tmp/netdisco-mibs');
	    # Install every MIB directory (not package-managed, hence /usr/local).
	    # All vendor folders are copied so that adding a new vendor to the
	    # repo needs no installer change. Netdot reads them from
	    # SNMP_MIBS_PATH (default.conf).
	    print "\nInstalling SNMP MIB files to /usr/local/netdisco/mibs\n";
	    &cmd('mkdir -p /usr/local/netdisco/mibs');
	    opendir(my $dh, '/tmp/netdisco-mibs')
		or die "Cannot read /tmp/netdisco-mibs\n";
	    my @mibdirs = grep { -d "/tmp/netdisco-mibs/$_" && $_ !~ /^\./ }
		readdir($dh);
	    closedir($dh);
	    for my $v (@mibdirs) {
		&cmd("cp -r /tmp/netdisco-mibs/$v /usr/local/netdisco/mibs/");
	    }
	    print "\nA new /etc/snmp/snmp.conf will be installed to point to the ".
		"newly installed MIB files. The current file will be backed up. ".
		"Continue? [y/n] ";
	    $ans = <STDIN>;
	    if ( $ans =~ /(Y|y)/ ){
		&cmd('mv -f /etc/snmp/snmp.conf /etc/snmp/snmp.conf.netdot_install');
		&cmd('cp /tmp/netdisco-mibs/EXTRAS/contrib/snmp.conf /etc/snmp/snmp.conf');
		print("\nDone with snmp.conf\n");
	    }
	    &cmd('rm -rf /tmp/netdisco-mibs');
	}
    }

    # Finally, lets call run_test to show the user if anything is missing
    print "\n===============RESULTS===============\n";
    &run_test();

    unless ( $action eq 'install' ){
	print "\nIf there are still any missing Perl modules, you can try:\n\n";
	print "    make installdeps\n\n"; 
    }

}

sub install_modules_cpan{

    $CPAN::Config->{prerequisites_policy}          = 'follow';
    $CPAN::Config->{ftp_passive}                   = '1';
    $CPAN::Config->{build_requires_install_policy} = 'yes';
    
    foreach my $anon_hash (@DEPS){
	my $module = $anon_hash->{'cpan'};
	next unless $module;

	eval "use $module";
	if ( $@ ){
	    $module =~ s/^(.*)\s+.*/$1/;
	    eval {
		CPAN::Shell->install($module);
	    };
	    
	    if ( my $e = $@ ){
		print $e;
	    }
	}
    }
}

sub run_test{
    foreach my $anon_hash (@DEPS){
	my $module = $anon_hash->{'cpan'} if exists $anon_hash->{'cpan'};
	next unless $module;
	eval "use $module";
	my $len = 50 - length($module);
	my $sep = '.' x $len;
	print $module."$sep";
	if ( $@ ){
	    print "MISSING";
	}
	else{
	    print "ok";
	}
	print "\n";
    }
}

# Run system commands
sub cmd {
    my $str = shift;
    if ( system($str) != 0 ){
	die "There was a problem running $str\n";
    }
}
