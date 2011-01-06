# IBM(c) 2010 EPL license http://www.eclipse.org/legal/epl-v10.html
#-------------------------------------------------------

=head1
  xCAT plugin package to handle the snmove command

=cut

#-------------------------------------------------------
package xCAT_plugin::snmove;

BEGIN
{
    $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}
use lib "$::XCATROOT/lib/perl";
use strict;
use xCAT::Table;
use xCAT::Utils;
use xCAT::NetworkUtils;
use xCAT::MsgUtils;
use Getopt::Long;
use xCAT::NodeRange;
use Data::Dumper;

1;

#-------------------------------------------------------

=head3  handled_commands

Return list of commands handled by this plugin

=cut

#-------------------------------------------------------

sub handled_commands
{
    return {snmove => "snmove",};
}

#-------------------------------------------------------

=head3  preprocess_request

  Preprocess the command

=cut

#-------------------------------------------------------
sub preprocess_request
{

    my $request  = shift;
    my $callback = shift;
    my $sub_req  = shift;
    my $command  = $request->{command}->[0];
    my $args     = $request->{arg};

    #if already preprocessed, go straight to process_request
    if (   (defined($request->{_xcatpreprocessed}))
        && ($request->{_xcatpreprocessed}->[0] == 1))
    {
        return [$request];
    }

    # let process_request handle it
    my $reqcopy = {%$request};
    $reqcopy->{_xcatpreprocessed}->[0] = 1;
    return [$reqcopy];

}

#-------------------------------------------------------

=head3  process_request

  Process the command

=cut

#-------------------------------------------------------
sub process_request
{
    my $request  = shift;
    my $callback = shift;
    my $sub_req  = shift;

    my $command = $request->{command}->[0];
    my $args    = $request->{arg};
	my $error=0;

    # parse the options
    @ARGV = ();
    if ($args)
    {
        @ARGV = @{$args};
    }
    Getopt::Long::Configure("bundling");
    Getopt::Long::Configure("no_pass_through");

    if (
        !GetOptions(
                    'h|help'        => \$::HELP,
                    'v|version'     => \$::VERSION,
                    's|source=s'    => \$::SN1,  # source SN akb MN
                    'S|sourcen=s'   => \$::SN1N, # source SN akb node
                    'd|dest=s'      => \$::SN2,  # dest SN akb MN
                    'D|destn=s'     => \$::SN2N, # dest SN akb node
                    'i|ignorenodes' => \$::IGNORE,
					'V|verbose'     => \$::VERBOSE,
        )
      )
    {
        &usage($callback);
        return 1;
    }

    # display the usage if -h or --help is specified
    if ($::HELP)
    {
        &usage($callback);
        return 0;
    }

    # display the version statement if -v or --verison is specified
    if ($::VERSION)
    {
        my $rsp = {};
        $rsp->{data}->[0] = xCAT::Utils->Version();
        $callback->($rsp);
        return 0;
    }

    if (@ARGV > 1)
    {
        my $rsp = {};
        $rsp->{data}->[0] = "Too many paramters.\n";
        $callback->($rsp);
        &usage($callback);
        return 1;
    }

    if ((@ARGV == 0) && (!$::SN1))
    {
        my $rsp = {};
        $rsp->{data}->[0] =
          "A node range or the source service node must be specified.\n";
        $callback->($rsp);
        &usage($callback);
        return 1;
    }

	#
	#  get the list of nodes
	#     - either from the command line or by checking which nodes are 
	#		managed by the servicenode (SN1)
	#
    my @nodes = ();
    if (@ARGV == 1)
    {
        my $nr = $ARGV[0];
        @nodes = noderange($nr);
        if (nodesmissed)
        {
            my $rsp = {};
            $rsp->{data}->[0] =
              "Invalid nodes in noderange:" . join(',', nodesmissed);
            $callback->($rsp);
            return 1;
       }
    }
    else
    {
        # get all the nodes that use SN1 as the primary service nodes
        my $pn_hash = xCAT::Utils->getSNandNodes();
        foreach my $snlist (keys %$pn_hash)
        {
            if (($snlist =~ /^$::SN1$/) || ($snlist =~ /^$::SN1\,/))
            {
                push(@nodes, @{$pn_hash->{$snlist}});
            }
        }
    }

	#
	#  get the node object definitions
	#
	my %objtype;
	my %nodehash;
	foreach my $o (@nodes)
	{
		$objtype{$o} = 'node';
	}
	my %nhash = xCAT::DBobjUtils->getobjdefs(\%objtype, $callback);
	if (!(%nhash))
	{
		my $rsp;
		push @{$rsp->{data}}, "Could not get xCAT object definitions.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

    my $rsp = {};
    $rsp->{data}->[0] = "Changing the service node for the following nodes: \n @nodes\n";
    $callback->($rsp);

	#
	# get the nimtype for AIX nodes  (diskless or standalone)
	#
	my %nimtype;
	if (xCAT::Utils->isAIX()) 
	{
		# need to check the nimimage table to find the nimtype
		my $nimtab = xCAT::Table->new('nimimage', -create => 1);
		if ($nimtab)
		{
			foreach my $node (@nodes)
			{
				my $provmethod = $nhash{$node}{'provmethod'};

				# get the nimtype
				my $ref = $nimtab->getAttribs({imagename => $provmethod},'nimtype');
				if ($ref)
				{
					$nimtype{$node} = $ref->{'nimtype'};
				}
			}
		}
	}

	#
	# get the backup sn for each node
	#
	my @servlist; # list of new service nodes
	my %newsn;
	my $nodehash;
	if ($::SN2) {  # we have the backup for each node from cmd line 
		foreach my $n (@nodes) {
			$newsn{$n}=$::SN2;
		}
		push(@servlist, $::SN2);
	} else {
		# check the 2nd value of the servicenode attr
		foreach my $node (@nodes)
		{
			if ($nhash{$node}{'servicenode'} ) {
				my @sn = split(',', $nhash{$node}{'servicenode'});
				if ( (scalar(@sn) > 2) && (xCAT::Utils->isAIX())) {
					print "Error - The service node attribute cannot have more than two values.\n";
				}

				if ($sn[1]) {
					$newsn{$node}=$sn[1];
					if (!grep(/^$sn[1]$/, @servlist)) {
						push(@servlist, $sn[1]);
					}
				}
			}

			if (!$newsn{$node}) {
				print "Could not determine a backup service node for node $node.\n";
				$error++;
			}
		}
	}

	#
	# get the new xcatmaster for each node
	#
	my %newxcatmaster;
	if ($::SN2N) {  # we have the xcatmaster for each node from cmd line
		foreach my $n (@nodes) {
			$newxcatmaster{$n}=$::SN2N;
		}
	} else {
		# try to calculate the xcatmaster value for each node

		# get all the interfaces from each SN
		# $sni{$SN}= list of ip
		my $s = &getSNinterfaces(\@servlist, $callback, $sub_req);

		my %sni = %$s;

		# get the network info for each node
		# $nethash{nodename}{networks attr name} = value
		my %nethash = xCAT::DBobjUtils->getNetwkInfo(\@nodes);

		# determine the xcatmaster value for the new SN
		foreach my $node (@nodes)
		{
			# get the node ip
			# or use getNodeIPaddress
			my $nodeIP = xCAT::NetworkUtils->getipaddr($node);
			chomp $nodeIP;

			# get the new SN for the node
			my $mySN = $newsn{$node};

			# check each interface on the service node
			foreach my $IP (@{$sni{$mySN}} ) {
				# if IP is in nodes subnet then thats the xcatmaster
				if(xCAT::NetworkUtils->ishostinsubnet($IP, $nethash{$node}{mask}, $nethash{$node}{net})) {
					# get the short hostname
					my $xcatmaster = xCAT::NetworkUtils->gethostname($IP);
					$xcatmaster =~ s/\..*//; 

					# add the value to the hash
					$newxcatmaster{$node}=$xcatmaster;
					last;
				}
			}
			if (!$newxcatmaster{$node}) {
				print "error: Could not determine an xcatmaster value for node $node.\n";
				$error++;
			}
		}
	}	

	#
	#  reset the node attribute values
	#
   	my %sn_hash;
   	my $old_node_hash = {};

	foreach my $node (@nodes)
	{
		my $sn1;
		my $sn1n;
                
		# get current xcatmaster
		if ($::SN1N) { # use command line value
		    $sn1n = $::SN1N; 
		} 
		elsif ($nhash{$node}{'xcatmaster'} ) {  # use xcatmaster attr
			$sn1n = $nhash{$node}{'xcatmaster'}; 
		}
		else
		{
			 my $rsp;
			 push @{$rsp->{data}}, "The current xcatmaster attribute is not set for node $node.\n";
			 xCAT::MsgUtils->message("W", $rsp, $callback);
		}

		# get the servicenode values
		my @sn_a;
		my $snlist = $nhash{$node}{'servicenode'};
		@sn_a = split(',', $snlist);

		# get current servicenode
		if ($::SN1) 
		{ 
			# current SN from the command line
			$sn1 = $::SN1; 
		}
        else 
		{ 
			# current SN from node attribute
			$sn1 = $sn_a[0]; 
		}

		# switch the servicenode attr list
		my @sn_temp = grep(!/^$newsn{$node}$/, @sn_a);
		unshift(@sn_temp, $newsn{$node});
		my $t = join(',', @sn_temp);

		$sn_hash{$node}{objtype} = 'node';

		# set servicenode and xcatmaster attr
		$sn_hash{$node}{'servicenode'}     = $t;
		$sn_hash{$node}{'xcatmaster'}      = $newxcatmaster{$node};
		$old_node_hash->{$node}->{'oldsn'}     = $sn1;
		$old_node_hash->{$node}->{'oldmaster'} = $sn1n;

		# set tftpserver
		if ($nhash{$node}{'tftpserver'} && ($nhash{$node}{'tftpserver'} eq $sn1n))
		{
			$sn_hash{$node}{'tftpserver'} = $newxcatmaster{$node};
		}

		# set nfsserver
		if ($nhash{$node}{'nfsserver'} && ($nhash{$node}{'nfsserver'} eq $sn1n))
		{
			$sn_hash{$node}{'nfsserver'} = $newxcatmaster{$node};
		}

		#set monserver  ( = "servicenode,xcatmaster" )
		if ($nhash{$node}{'monserver'})
		{
			my @tmp_a = split(',', $nhash{$node}{'monserver'});
			if ((@tmp_a > 1) && ($tmp_a[1] eq $sn1n))
			{
				$sn_hash{$node}{'monserver'} = "$newsn{$node},$newxcatmaster{$node}";
			}
		}
	}

    my $rsp;
	push @{$rsp->{data}}, "Setting new values in the xCAT database.\n";
	xCAT::MsgUtils->message("I", $rsp, $callback);

	if (keys(%sn_hash) > 0)
	{
		# update the node definition
		if (xCAT::DBobjUtils->setobjdefs(\%sn_hash) != 0)
		{
			my $rsp;
			push @{$rsp->{data}}, "Could not update xCAT node definitions.\n";
			xCAT::MsgUtils->message("E", $rsp, $::callback);
			$error++;
		}
	}

	#
    # handle conserver
	#
    my %sn_hash1;
	foreach my $node (@nodes)
	{
		if (($nhash{$node}{'conserver'})  and ($nhash{$node}{'conserver'} eq $old_node_hash->{$node}->{'oldsn'})) {
			$sn_hash1{$node}{'conserver'} = $newsn{$node};
			$sn_hash1{$node}{objtype} = 'node';
		}
	}

	# update the node definition
	if (keys(%sn_hash1) > 0)
	{
		if (xCAT::DBobjUtils->setobjdefs(\%sn_hash1) != 0)
		{
			my $rsp;
			push @{$rsp->{data}}, "Could not update xCAT node definitions.\n";
			xCAT::MsgUtils->message("E", $rsp, $::callback);
			$error++;
		}
	}

	# run makeconservercf
    my @nodes_con = keys(%sn_hash1);
    if (@nodes_con > 0)
    {
        my $rsp = {};
        $rsp->{data}->[0] = "Running makeconservercf " . join(',', @nodes_con);
        $callback->($rsp);

        my $ret =
          xCAT::Utils->runxcmd(
                               {
                                command => ['makeconservercf'],
                                node    => \@nodes_con,
                               },
                               $sub_req, 0, 1
                               );
        $callback->({data => $ret});
    }

	#
	#   Run niminit on AIX diskful nodes
	#
	if (!$::IGNORE) # unless the user does not want us to touch the node
	{
		if (xCAT::Utils->isAIX())
		{
			#if the node is aix and the type is standalone
			foreach my $node (@nodes)
			{
				# if this is a standalone node then run niminit
				if (($nimtype{$node}) && ($nimtype{$node} eq 'standalone')) {

					my $nimcmd = qq~/usr/sbin/niminit -a name=$node -a master=$newsn{$node} >/dev/null 2>&1~;
					
					my $out = xCAT::InstUtils->xcmd($callback, $sub_req, "xdsh", $node, $nimcmd, 0);

					if ($::RUNCMD_RC != 0)
					{
						my $rsp;
						push @{$rsp->{data}}, "Could not run niminit on node $node.\n";
						xCAT::MsgUtils->message("E", $rsp, $callback);
						$error++;
					}
				}
			}
		}
	}

	# for Linux system only
    if (xCAT::Utils->isLinux())
    {
        #tftp, dhcp and nfs (site.disjointdhcps should be set to 1)

		# get a list of nodes for each provmethod
        my %nodeset_hash;
        foreach my $node (@nodes)
        {
			my $provmethod = $nhash{$node}{'provmethod'};
			if ($provmethod)
			{
				if (!grep(/^$node$/, @{$nodeset_hash{$provmethod}})) {
					push(@{$nodeset_hash{$provmethod}}, $node);
				}
            }
        }

		# run the nodeset command
        foreach my $provmethod (keys(%nodeset_hash))
        {
			# need a node list to send to nodeset
			my $nodeset_nodes = join ',', @{$nodeset_hash{$provmethod}};

			if (($provmethod eq 'netboot') || ($provmethod eq 'install') || ($provmethod eq 'statelite')) 
            {
                my $ret =
                  xCAT::Utils->runxcmd(
                                       {
                                        command => ['nodeset'],
                                        node    => $nodeset_nodes,
                                        arg     => [$provmethod],
                                       },
                                       $sub_req, 0, 1
                                       );
				if ($::RUNCMD_RC != 0)
				{
					my $rsp;
					push @{$rsp->{data}}, "Could not run the nodeset command.\n";
					xCAT::MsgUtils->message("E", $rsp, $callback);
					$error++;
				}
            }
            else
            {
                my $ret = xCAT::Utils->runxcmd( {command => ['nodeset'], node    => $nodeset_nodes, arg     => ["osimage=$provmethod"],}, $sub_req, 0, 1 );
				if ($::RUNCMD_RC != 0)
				{
					my $rsp;
					push @{$rsp->{data}}, "Could not run the nodeset command.\n";
					xCAT::MsgUtils->message("E", $rsp, $callback);
					$error++;
				}
            }
        }
	} # end - for Linux system only    

	#
	# for both AIX and Linux systems
	#
    # run postscripts to take care of syslog, ntp, and mkresolvconf 
	#	 - if they are icluded in the postscripts table
    if (!$::IGNORE) # unless the user does not want us to touch the node
    {
		# get all the postscripts that should be run for the nodes
        my $pstab = xCAT::Table->new('postscripts', -create => 1);
        my $nodeposhash = {};
        if ($pstab)
        {
            $nodeposhash =
                  $pstab->getNodesAttribs(\@nodes,
                                          ['postscripts', 'postbootscripts']);
        }
        else
        {
            my $rsp = {};
            $rsp->{error}->[0] = "Cannot open postscripts table.\n";
            $callback->($rsp);
            return 1;
        }

        my $et =
          $pstab->getAttribs({node => "xcatdefaults"},
                                 'postscripts', 'postbootscripts');
        my $defscripts     = "";
        my $defbootscripts = "";
        if ($et)
        {
            $defscripts     = $et->{'postscripts'};
            $defbootscripts = $et->{'postbootscripts'};
        }

        my $pos_hash = {};
        foreach my $node (@nodes)
        {

			if (($nimtype{$node}) && ($nimtype{$node} eq 'diskless')) {
				# don't run scripts on AIX diskless nodes 
				#	- they will have to be rebooted anyway.
				next;
			}

            foreach my $rec (@{$nodeposhash->{$node}})
            {
                my $scripts;
                if ($rec)
                {
                    $scripts = join(',',
                                    $defscripts,
                                    $defbootscripts,
                                        $rec->{'postscripts'},
                                        $rec->{'postsbootcripts'});
                }
                else
                {
                    $scripts = join(',', $defscripts, $defbootscripts);
                }
                my @tmp_a = split(',', $scripts);

				# only consider running syslog, setupntp, and mkresolvconf
				my @valid_scripts = ("syslog", "setupntp", "mkresolvconf");
                my $scripts1="";
				foreach my $s (@valid_scripts) {

					# if it was included in the original list then run it
					if (grep(/^$s$/, @tmp_a))
					{
						if ($scripts1) { 
							$scripts1 = "$scripts1,$s"; 
						}
						else
						{
							$scripts1 = $s;
						}
					}
				}

                if ($scripts1)
                {
                     if (exists($pos_hash->{$scripts1}))
                    {
                        my $pa = $pos_hash->{$scripts1};
                        push(@$pa, $node);
                    }
                    else
                    {
                        $pos_hash->{$scripts1} = [$node];
                    }
                }
            }
        }

        foreach my $scripts (keys(%$pos_hash))
        {
            my $pos_nodes = $pos_hash->{$scripts};
            my $ret =
                  xCAT::Utils->runxcmd(
                                       {
                                        command => ['updatenode'],
                                        node    => $pos_nodes,
                                        arg     => ["-P", $scripts, "-s"],
                                       },
                                       $sub_req, 0, 1
                                       );
			if ($::RUNCMD_RC != 0)
			{
				my $rsp;
				push @{$rsp->{data}}, "Could not run the updatenode command.\n";
				xCAT::MsgUtils->message("E", $rsp, $callback);
				$error++;
			}
        }
    } # end -for both AIX and Linux systems

	my  $retcode=0;
    if ($error)
	{
		my $rsp;
		push @{$rsp->{data}}, "One or more errors occurred while attempting to switch nodes to a new service node.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		$retcode = 1;
	}
	else
	{
		my $rsp;
		push @{$rsp->{data}}, "The nodes were successfully moved to the new service node.\n";
		xCAT::MsgUtils->message("I", $rsp, $callback);
	}

	return  $retcode;

}

#----------------------------------------------------------------------------

=head3  getSNinterfaces

	Get a list of ip addresses for each service node in a list

	Arguments:
		list of servcie nodes
	Returns:
		1 -  could not get list of ips
		0 -  ok
	Globals:
		none
	Error:
		none
	Example:
		my $sni = xCAT::InstUtils->getSNinterfaces(\@servlist);

	Comments:
		none

=cut

#-----------------------------------------------------------------------------
sub getSNinterfaces
{
	#my ($class, $list, $callback, $subreq) = @_;
	my ($list, $callback, $subreq) = @_;

	my @snlist = @$list;

	my %SNinterfaces;

	# get all the possible IPs for the node I'm running on
	my $ifcmd;
	if (xCAT::Utils->isAIX())
	{
		$ifcmd = "/usr/sbin/ifconfig -a ";
	}
	else
	{
		$ifcmd = "/sbin/ip addr ";
	}

	foreach my $sn (@snlist) {

		my $SNIP;

		my $result = xCAT::InstUtils->xcmd($callback, $subreq, "xdsh", $sn, $ifcmd, 0);
		if ($::RUNCMD_RC != 0)
		{
			print "Could not get IP addresses from service node $sn.\n";
			next;
		}

		foreach my $int ( split(/\n/, $result) )
		{
			if (!grep(/inet/, $int))
			{
				# only want line with "inet"
				next;
			}
			$int =~ s/$sn:\s+//; # skip hostname from xdsh output
			my @elems = split(/\s+/, $int);

			if (xCAT::Utils->isLinux())
			{
				if ($elems[0] eq 'inet6')
				{
					#Linux IPv6 TODO, do not return IPv6 networks on 
					#	Linux for now
					next;
				}

				($SNIP, my $mask) = split /\//, $elems[1];
			}
			else
			{
				# for AIX
				if ($elems[0] eq 'inet6')
				{
					$SNIP=$elems[1];
					$SNIP =~ s/\/.*//; # ipv6 address 4000::99/64
					$SNIP =~ s/\%.*//; # ipv6 address ::1%1/128
				}
				else 
				{
					$SNIP = $elems[1];
				}
			}

			chomp $SNIP;

			push(@{$SNinterfaces{$sn}}, $SNIP);
		}
	}

	return \%SNinterfaces;
}

#-----------------------------------------------------------------------------
sub usage
{
    my $cb  = shift;
    my $rsp = {};

    push @{$rsp->{data}},
      "\nsnmove - Move xCAT compute nodes from one xCAT service node to a \nbackup service node.";
    push @{$rsp->{data}}, "\nUsage: ";
    push @{$rsp->{data}}, "\tsnmove -h";
    push @{$rsp->{data}}, "or";
    push @{$rsp->{data}}, "\tsnmove -v";
    push @{$rsp->{data}}, "or";
    push @{$rsp->{data}},
      "\tsnmove noderange [-d sn2] [-D sn2n] [-i|--ignorenodes]";
    push @{$rsp->{data}}, "or";
    push @{$rsp->{data}},
      "\tsnmove -s sn1 [-S sn1n] [-d sn2] [-D sn2n] [-i|--ignorenodes]";
    push @{$rsp->{data}}, "\n";
    push @{$rsp->{data}}, "\nWhere:";
    push @{$rsp->{data}},
      "\tsn1 is the hostname of the source service node as known by (facing) the management node.";
    push @{$rsp->{data}},
      "\tsn1n is the hostname of the source service node as known by (facing) the nodes.";
    push @{$rsp->{data}},
      "\tsn2 is the hostname of the destination service node as known by (facing) the management node.";
    push @{$rsp->{data}},
      "\tsn2n is the hostname of the destination service node as known by (facing) the nodes.";
    $cb->($rsp);

    return 0;
}

