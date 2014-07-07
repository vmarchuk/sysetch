#!/bin/env perl
# Name: Etch
# Author: Walter Marchuk

# Make sure all perl modules exist before using


# list of things to share with external scripts - do not modify here, modify in hooks
our @SAFESHARE = ('$force', '$debug', '$dryrun', '$OS', '$OSVERSION', '$ARCH', '$FULLARCH', '$HOSTNAME', '@DUTIES', '@CLUSTERS', '@LOCATION', '@HARDWARE', '$LINUXDISTRO', '$LINUXDISTROVERSION', '%HOOKS', '$FILE', '$RSYNC_SRC', '$ARG', '@ARGS', '$FILEBASE', '$DIR', '$ORIGINAL_FILE', '*CONFIG', '*STDOUT', '*STDERR', '$rperms', '$perms', '$owner', '$group', '$rowner', '$rgroup', '$uid', '$gid', '&compare_link_destination', '&compare_file_contents', '&compare_permissions', '&compare_ownership', '&chmod', '&chown', '&octify', '&symlink', '&readfile', '&warn', '&bug', '&log');

#BEGIN
#{
	#our @PERLMODULES=();
	
#'Getopt::Long', 'XML::Twig', 'XML::XPath', 'Safe', 'Opcode', 'File::Basename',
#, 'File::Path'
#, 'File::Spec'
#, 'File::Find'
#, 'Cwd qw(abs_path)', 'File::stat;Fcntl', 'Term::ANSIColor'
#, 'Cache::FileCache'
#, 'Digest::MD5 qw(md5_hex)'
#, 'Data::Dumper'
#}

#################################################
# no user defined variables below
#################################################

# core modules
use Opcode;
use Safe;
use File::Basename;  # dirname
use File::Path;      # mkpath
use File::Spec;      # canonpath
use File::Find;      # find
use File::stat;
use Cwd qw(abs_path);
use Fcntl;           # Modes for sysope
use Getopt::Long;
use Term::ANSIColor;
use Digest::MD5 qw(md5_hex);
use Data::Dumper;

# additional modules located in $prefix/lib/perl
use XML::Twig;
use XML::XPath;
use Cache::FileCache;

our $DIV="----------------------------------\n";

$| = 1;

#
# Parse the command line options
#
&parsecommandline();

#
# Load the system variables
#
&initsystem();
&listsystem('init');

#
# Perform whatever operation the user requested
#

# Start program
&main();

# End program
&quit(0);

#
# Subroutines
#

# Main loop
sub main()
{
	&log("Starting Etch with arguments: ". join(' ', @origARGV), 2);

	# loop through sources
	my $i=0;
	foreach our $SOURCEBASE ( @SOURCES )
	{
		our $currently_locked_file = undef;
		our %GENERATED = undef; # Hash used to track of processed dependencies to avoid multiple extra loops
		$GENERATED{'regex'} = (); # array used for matching wildcards
		our %GENERATETEST = undef; # Hash used to for generate/runas subroutines to let know if they will perform work

		# display source we are working on
		&log($DIV) if ($i > 0);
		&log("SOURCE: $SOURCEBASE ". ($dryrun == 9?'(LIST)':($dryrun?'(DRYRUN)':'')) ."\n");

		foreach $manualfile ( @manualfiles )
		{
			our $PROCESS_rsync=undef;

			while ($manualfile =~ /(.*?)\/$/) { $manualfile = $1;}
			if (!$manualfile) { $manualfile = '/'; $generateall=1; }
			&generateall($manualfile, '', $dryrun);
		}
		$i++;
	}
}

# Generate all files
# Accepts 'skip' to skip processing of anything below, which is used for cyclical depency checking
sub generateall($$$)
{
	my ($file, $skip, $dryrun) = @_;

	# returns true if found to be already generated
	# even though we can just use $tmpbase we are still using %GENERATED for speed, since it doesnt have to 
	# parse $tmpbase except on special occasions like if we have run runas
	sub findgenerated
	{
		my $file = shift;
		return 1 if ( exists $GENERATED{$file} );
		return 1 if ( grep { $file =~ /^$_/  } @{$GENERATED{'regex'}} );

		# check inside tmpbase file if we have sudo'd a process
		return ($IPC->get($file)) if (defined $beenRUNAS);
	}

	sub look_for_config_xml                                                                                                  
	{                                                                                                                        
        	my ($file, $skip, $dryrun) = @_;                                                                                 
        	if ($_ eq 'config.xml' || $_ eq 'config.xml.disabled' || $_ eq 'conf.xml' || $_ eq 'conf.xml.disabled')          
        	{                                                                                                                
                	my $disabled = 1 if ($_ eq 'config.xml.disabled' || $_ eq 'conf.xml.disabled');                          
                                                                                                                         
                	# Strip $SOURCEBASE from $File::Find::dir                                                                
                	my $thisfile = $File::Find::dir;                                                                         
                	$thisfile =~ s/^$SOURCEBASE//;                                                                           

                	if ($disabled)                                                                                           
                	{                                                                                                        
                        	our @CONFIGPATHDISABLED if (!defined @CONFIGPATHDISABLED);                                       
                        	push(@CONFIGPATHDISABLED, $thisfile);                                                            
                	}                                                                                                        
                                                                                                                         
                	return if ( ($skip && $thisfile =~ /^$skip(\/|$)/) || (grep { $thisfile =~ /^$_(\/|$)/ } @CONFIGPATHDISABLED) );

                	unless (&findgenerated($thisfile))    
                	{                                                                                                        
				if ($dryrun eq 'process')
				{ 
					my $ret = &generate($thisfile, $dryrun, 0);
				}
				else
				{
                        		$GENERATED{$thisfile} = 1;                                                                       
                        		eval{   
						no warnings;                                                                             
                                		print IPC "GENERATED:${thisfile}\n";                                                     
                                		%GENERATETEST = %{$IPC->get('GENERATETEST')};                                            
                        		};                                                                                               
                        		my $ret = &generate($thisfile, $dryrun, 0);                                                      
                        		push(@CONFIGPATHDISABLED, $thisfile) if ($ret == 100);                                           
                        		if ($ret != 100)                                                                                 
                        		{                                                                                                
                                		eval{   
							no warnings;                                                                     
                                        		$IPC->set('GENERATETEST', \%GENERATETEST);                                       
                                        		print IPC "GENERATED:${thisfile}:DONE\n";                                        
                                        		$IPC->set($thisfile, '1') if ($ret != 2);                                        
                                		};                                                                                       
                        		}                                                                                                
                		}                                                                                                        
			}
        	}                                                                                                                
	} 

	# process parent directories for setup information, currently used for rsync info
	if ($file ne '/')
	{
		my @files = split('/', $file);
		pop(@files);
		my $f;
		my $maxdepth=0;
		foreach my $dir ( split('/', $file) )
		{
			$maxdepth++;
			$f .= ($f ne '/'?'/':''). $dir;
			my ($varf) = &translatepath($f, 'var');
			find( { preprocess => sub { 
					my $depth = $File::Find::dir =~ tr[/][];  
					return @_ if ($depth < $max_depth - 1);
					return grep { not -d } @_;
				}, 
				wanted => sub { &look_for_config_xml($f, $skip, 'process'), } 
			      }, $SOURCEBASE.$varf);
		}
	}
	# if wildcard is present, look for contents inside $file
        my ($varfile) = &translatepath($file, 'var');
	find( { wanted => sub { &look_for_config_xml($file, $skip, $dryrun) } }, $SOURCEBASE.$varfile);	

	# file was not generated, check if this file is part of rsync process
	if ($file ne '/' && !&findgenerated($varfile) && $PROCESS_rsync)
	{
		foreach my $type ( ('setup', 'directory') )
		{
			our $FILE = $PROCESS_rsync->{parent};
			if (&ismine("/config/$type/rsync", $PROCESS_rsync->{xpath}, "START Etching $FILE via rsync process". ($dryrun?'(DRYRUN)':'') ."\n") && $dryrun != 9)
			{
				&process_rsync($type, $file, $PROCESS_rsync->{xpath}, $dryrun, $PROCESS_rsync);
				&logprepop();
				&log("END Etching $FILE via rsync process". ($dryrun?'(DRYRUN)':'') ."\n");
			}
		}
	}
}

# translates dynamic paths with variables
# returns array of files
# mode can set which path we need to see, variable or translated
sub translatepath
{
	my $src = shift;
	return ( ('/') ) if ($src eq '/');

	my $mode = shift || 'auto'; # auto | var | translated
	my @dst = ('');
	my ($srcOrig, $srcOrigBase);
	#print "translatepath($src, $mode)\n";
       	foreach my $i ( split('/', $src) )
       	{ 
               	next if ($i eq '');  
		my $matched=0;
		
		$srcOrigBase = $srcOrig;
		$srcOrig .= "/$i";

		#print "$mode - $i\n";
               	if ($mode ne 'var' && $i =~ /\@/)
               	{ 
			my $regex = $i; $regex =~ s/\@/(\.\*\?)/g; $regex = qr/^$regex$/;
			#&log("- [1] Variable path encountered: $i, regex: $regex\n", 8);	
                       	my @dstOrig=@dst;                                                                                                                                                                  
                       	@dst=();
                       	foreach my $duty (@DUTIES)
                      	{ 
				if ($duty =~ $regex)
                               	{
                                       	foreach my $x (@dstOrig)
                                       	{ 
                                               	push(@dst, "$x/$1"); 
                                       	}       
                               	}
                       	} 
                       	if (!@dst)
                       	{ 
				&log("Unable to translate path: $src\n", 8);
                               	return 100;
                       	}
			$matched=1;
               	}                          
               	else                                  
               	{       
			my $dir = $SOURCEBASE . $srcOrigBase;
			my @files = map { basename($_) } <$dir/*\@*>;
			foreach my $duty (@DUTIES)
			{
				foreach my $f ( @files )
				{
					my $regex = $f; $regex =~ s/\@/(\.\*\?)/g; $regex = qr/^$regex$/;
					if ($duty =~ $regex && $i eq $1 && ! -d "$dir/$1")
					{
						@dst = map { "$_/$f" } @dst;
						#&log("\tMatching variable, $i, to duty: $duty - $srcOrig\n", 8);
						$srcOrig="$srcOrigBase/$f";
						$matched=1;
						last;
					}
				}
			}
		}

		@dst = map { "$_/$i" } @dst if (!$matched);	
       	} 
	#print Dumper @dst;
	return @dst;
}

# NOTE:  Do not use a bare return to exit the generate subroutine.
# You'll leave the file locked.  Use
# 'return unlock_currently_locked_file()' instead.
# returns 100 to let caller know to not proceed further
sub generate
{
	my $dst = shift || &bug("Missing \$file in &generate()");
	my $dryrun = shift;  # Can be false or process
	my $test = shift; # Can be false, used for testing if we are searching for files, 
			  # each sub will create $GENERATETEST{'subroutinename'} with arguments that were given
	my $ret;
	my $ret1=100;	

	#my $xpath = &readconfig("$SOURCEBASE/". ${&translatepath($dst, 'var')}[0]);
	my $xpath = &readconfig("$SOURCEBASE/$dst");
	chdir "$SOURCEBASE/$dst" || &away("chdir to $SOURCEBASE/$dst:  $!\n");

	#&log("generate($dst : $manualfile)\n");

	foreach my $file ( &translatepath($dst) )
	{
		# process method, invoked from generateall to process parent directories
		# currently used for rsync
		if ($dryrun eq 'process') 
		{ 
			if ( $xpath->exists("/config/setup/rsync") || $xpath->exists("/config/directory/rsync"))
			{
				our $PROCESS_rsync = { process => 1, xpath => $xpath, parent => $file };
				&log("PROCESS $file (rsync config found)\n", 7);
			}
			else { &log("PROCESS $file\n", 7); }
			next;
		}

		next if ( !$generateall && $manualfile && $file !~ /^$manualfile(\/|$)/);

                our $FILE=$file;

		$ret1=0;

		# check if we need to reconnect
		return($ret) if( $ret = &process_connect($file, $xpath, $test) );
		
		# Check if we need to we have a runas, ie: run as another user
		return($ret) if( $ret = &process_runas($file, $xpath, $test) );

		# for tracking if statements below
		my $done = 0;

		if (!$test && $dryrun != 9)
		{
			# lock file
        		&lock_file($file);
        		$currently_locked_file = $file;
			
        		# If we're in timestamp mode just check the file timestamps first to
        		# see if we should proceed.
        		return &unlock_currently_locked_file() if ($timestamp && !&check_timestamp($file));
		}

		# Check to see if the user has requested that we revert back to the
		# original file.
		if ($xpath->exists('/config/revert'))
		{
			# *** Doesnt work yet...
			&away("Revert is not yet functional");	
		}
	
		# See what type of action the user has requested
		# The double braces allow us to use the 'last' command to break out
		# of one type of action when we determine that it isn't applicable
		# on this host and move on to testing other types of action.  See
		# the perlsyn man page for more details on using last inside 'if'
		# blocks.

		# Regular file
		$done = &generate_file($file, $xpath, $dryrun, $test) if ($xpath->exists('/config/file') && !$done);
	
		# Symbolic link
		$done = &generate_link($file, $xpath, $dryrun, $test) if ($xpath->exists('/config/link') && !$done);  # Symbolic link
	
		# Directory
		$done = &generate_directory($file, $xpath, $dryrun, $test) if ($xpath->exists('/config/directory') && !$done);
	
		# Delete whatever is there
		$done = &generate_delete($file, $xpath, $dryrun, $test) if ($xpath->exists('/config/delete') && !$done);
	
		if (!$test)
		{
			update_timestamp($file);
			unlock_currently_locked_file() if (!$test);
		}
		
		# Run post runas
		&logprepop();
		&log("END Etching $FILE ". ($dryrun?'(DRYRUN)':'') ."\n") if ($dryrun != 9 && $ISMINE);
		return($ret) if( $ret = &process_runas($file, $xpath, $test, 'post') );
	}

	return $ret1 if ($ret1);
	return($ret);
}

sub process_connect($$$)
{
	my ($file, $xpath, $test) = @_;

	my $connect;
        # connect or pre mode
        # switch from previous 'higher-level' file
        if ($xpath->exists("/config/connect") && $etchpush && $etchpush ne 'default' && !$generateall)  
        # if we are connected using default, then we never switch to another connect
        {
        	my $string = sprintf('%s', $xpath->getNodeText("/config/connect") || 'default'); # force convert to string for md5_hex
                # compare if we are using the same connect method
                if ($etchpush ne md5_hex($string) )
                {
                        $connect = $string;
                        if ($test)
                        {
                                $GENERATETEST{'runas_connect'} = $connect;
                                return(1);
                        }       
                }
                delete $GENERATETEST{'connect'} if (exists $GENERATETEST{'connect'});
        }
        elsif(exists $GENERATETEST{'connect'} && !$test)
        {
                # if runas/connect was set previously
                $connect = $GENERATETEST{'connect'};
                delete $GENERATETEST{'connect'};
        }

	return(0) if (!$connect);

        # better to do another runas after this one finishes
        if ($runas && !$ACK)
        {
                # if we are here this means we need to switch to another user but we already are in 
                # runas mode.  nested connect is not allowed simply because it would be cleaner to let
                # parent spawn another connect since most likely parent is root
                push(@{$GENERATED{'regex'}}, $file);
                return(2);
        }

        # Push mode
	if ($connect)
	{
        	$connect =~ s/\n//g;
		&log("Requesting new connect method for $file.\n", $debug);
        	&log($DIV, $debug);
        	&ipc_etchpush($file, $connect, 'connect');
        	&log($DIV, $debug);
        	&log("Done with new connect method for $file.\n", $debug);
        	return(1);
	}
	return(0);
}

# su user if requested or reconnect if in etchpush mode
sub process_runas
{
	my $file = shift || &bug("missing filename");
	my $xpath = shift || &bug("missing xpath");
	my $test = shift || 0;
	my $when = shift || 'pre'; # used for triggering post mode

	my ($newuser, $newuid, $mode);

	# Activate post runas
	# GENERATETEST will always use 'post' as priority over 'pre'
	
	if ($GENERATETEST{'runas_sudo_post'} && !$test)
	{
		$file .= "/*" if ($when eq 'post');
       		$newuser = $GENERATETEST{'runas_sudo_post'};
		delete $GENERATETEST{'runas_sudo_post'};	
	}

	if ($when ne 'post')
	{
		if ($xpath->exists("/config/runas") && !$newuser)
		{
			my $pre =  sprintf('%s', $xpath->getNodeText("/config/runas[\@when='pre']")  || 'TEXT_NOT_FOUND');	
			my $post = sprintf('%s', $xpath->getNodeText("/config/runas[\@when='post']") || 'TEXT_NOT_FOUND');
			if ($post ne 'TEXT_NOT_FOUND')
			{
				if ($test) { $GENERATETEST{'runas_sudo_pre'} = $post; }
				else       { $GENERATETEST{'runas_sudo_post'} = $post; }
			}
			elsif ($test && $pre ne 'TEXT_NOT_FOUND')
			{
				$GENERATETEST{'runas_sudo_pre'} = $pre;
				return(1);
			}
		}
        	elsif(exists $GENERATETEST{'runas_sudo_pre'} && !$test)
        	{
			# We are here because $test set this from higher level
               		$newuser = $GENERATETEST{'runas_sudo_pre'};
			delete $GENERATETEST{'runas_sudo_pre'};
        	}

		if (exists $GENERATETEST{'runas_sudo_pre'} && !$test)
		{
			$newuser = $GENERATETEST{'runas_sudo_pre'};
			delete $GENERATETEST{'runas_sudo_pre'};
		}
	}

	# exit if $newuser is not set
	return 0 if (!$newuser);

       	# verify if newuser is valid user       
       	$newuid = &lookup_uid($newuser);

       	# currently running as runas user
       	return(0) if ($newuid == $SYSTEMUID);

      	# better to do another runas after this one finishes
       	if ($runas && !$ACK) 
       	{
               	# if we are here this means we need to switch to another user but we already are in 
               	# runas mode.  nested runas is not allowed simply because it would be cleaner to let
               	# parent spawn another sudo since most likely parent is root
               	push(@{$GENERATED{'regex'}}, $file);
        	return(2);
        }

	&log("Switching user to $newuser for $file\n", 6);

        # Verify if we can switch users via sudo
        # if root, then dont bother checking
        my $sudo;
        foreach my $path (split(/:/, $ENV{'PATH'}))
        {
                if ( -x "$path/sudo")
                {
                        $sudo = "$path/sudo";
                        last;
                }
        }

        if ($sudo)
        {
                my $i;
                my $cmd;
                # check sudo if etch is in the list
                if ($SYSTEMUID != 0)
                {
                        $cmd = "$sudo -S -l";
                        $i = `$cmd 2>&1 </dev/null`;
                        if ($? != 0)
                        {
                                &away("ERROR! Problem with running following command: $cmd\n");
                        }
                        elsif ( $i !~ /\($newuser\) NOPASSWD: $0/ )
                        {
                                &away("ERROR! User '$SYSTEMOWNER' does not have sudo to etch $file via user '$newuser'");
                        }
                }

                # test etch via sudo
                $cmd = "$sudo -S -u $newuser $0 --test";
                `$cmd 2>&1 </dev/null`;
                &away("ERROR! Problem with running following command: $cmd") if ($? != 0);
        }
        else
        {
                &away("ERROR! Unable to detect 'sudo' binary for $file\n");
        }

        &unlock_currently_locked_file();
        &log("Running etch as user '$newuser' from '$SYSTEMOWNER' for $file\n", $debug);
	&log($DIV, $debug);
        my @cmd = ($sudo, '-S', '-u', $newuser, $0, $file, @OPTIONS);
        &log("\t". join(' ', @cmd) ."\n", 6);
        open CMD, '-|' or exec @cmd, "--runas=$PS", "2>&1";
        while(<CMD>)
        {
                print $_;
        }
        close(CMD);

        &away("ERROR:$? detected in runas $newuser for $file") if ($? != 0);
        &log($DIV, $debug);
        &log("Done with etch as user $newuser for $file\n", $debug);

        # let outside know that we have sudo'd
        our $beenRUNAS = 1;

        # Run post runas
	&process_runas($file, $xpath, $test, 'post') if ( $GENERATETEST{'runas_sudo_post'} );

        return(1);
}

sub generate_file($$$$)
{
	my ($file, $xpath, $dryrun, $test) = @_;

        # Assemble the new contents for the file
        my $newcontents = '';

        if (&ismine('/config/file/source/plain', $xpath) && $dryrun != 9)
        {
		my @nodes = $xpath->findnodes("/config/file/source/plain");

		eval { &process_depend($file, $xpath, $dryrun); };
		&perminfo($file, $xpath, 'file');
		&makepath($file, $dryrun, '0755');
        	&process_setup($file, $xpath, $dryrun);

        	my @plainnodes = $xpath->findnodes('/config/file/source/plain');
                &check_for_inconsistency($file, @plainnodes);

                # Just slurp the file in
                my $plain = $plainnodes[0]->string_value;
                open(FILE, '<', $plain) || &away("open $plain for $file:  $!\n");
                while(<FILE>) { $newcontents .= $_; }
                close(FILE);

		# process the file if template option is enabled
		if ($nodes[0]->getAttribute('template') eq 'true')
		{
			my $process = \&process_script;
			$newcontents =~ s/(::ETCH:.*?\(.*?\)::)/$process->($1, $file, $xpath)/ge;
		}
        }
        elsif (&ismine('/config/file/source/script', $xpath) && $dryrun != 9)
        {
		eval { &process_depend($file, $xpath, $dryrun); };
		&perminfo($file, $xpath, 'file');
		&makepath($file, $dryrun, '0755');
        	&process_setup($file, $xpath, $dryrun);

        	$newcontents = &process_script('file/source', $file, $xpath);
        }
	elsif (&ismine('/config/file/perms_only', $xpath) && $dryrun != 9)
	{
		eval { &process_depend($file, $xpath, $dryrun); };
		&perminfo($file, $xpath, 'file');
		&makepath($file, $dryrun, '0755');
        	&process_setup($file, $xpath, $dryrun);

		# perms only
		&log("Permission change only\n", $debug);
        	unless ( compare_permissions($file, $perms) || compare_ownership($file, $uid, $gid) )
        	{
                	&log("\tno permissions change necessary\n", $debug);
                	return(1);
        	}

        	# Ensure the permissions are set properly                                                                                                                                                                    
        	&chmod($perms, $file, $debug);
	
        	# Ensure the ownership is set properly                                                                                                                                                                       
        	&chown($uid, $gid, $file, $debug);
        	return(0);

		
	}
        else
        {
        	# If the filtering has removed the source for this file's
                # contents, that means it doesn't apply to this host.
                &log("No source for $file contents, doing nothing\n", 7) if ($dryrun != 9);
		return(0);
        }

	if ($test)
	{
        	# we need to inform above that we need to proceed with runas
        	if (defined $test && $test)
        	{
                	@{$GENERATETEST{'generate_file'}} = ($file, $xpath, $dryrun, 0);
                	return(1);
        	}
	}	

        &log("Generating $file (FILE)\n", $debug);

        # If the new contents are empty, and the user hasn't asked us to
        # keep empty files, then assume this file is not applicable to
        # this host and do nothing.
        my $allow_empty = $xpath->exists('/config/file/allow_empty') || $defaults_xpath->exists('/config/file/allow_empty');
        if ( $xpath->exists('/config/file/script_only') )
        {
		if (!$newcontents) { &log("\tno change necessary\n", $debug); }
		else { &log("$newcontents\n", 6); }	
		return(1);
        }

        if ($newcontents eq '' && !$allow_empty)
        {
        	&log("New contents for $file empty, doing nothing\n", $debug);
		return(0);
        }

        # Add the warning message (if defined)
        my $warning_file = '';
        if ($xpath->exists('/config/file/warning_file'))
        {
        	$warning_file = $xpath->getNodeText('/config/file/warning_file');
        }
        elsif ($defaults_xpath->exists('/config/file/warning_file'))
        {
        	$warning_file = $defaults_xpath->getNodeText('/config/file/warning_file');
        }
        if ($warning_file)
        {
        	my $message = '';

                # First the comment opener
                my $comment_open = '';
                if ($xpath->exists('/config/file/comment_open'))
                {
                	$comment_open = $xpath->getNodeText('/config/file/comment_open');
                }
                elsif ($defaults_xpath->exists('/config/file/comment_open'))
                {
                        $comment_open = $defaults_xpath->getNodeText('/config/file/comment_open');
                }
                if ($comment_open)
                {
                        $message .= $comment_open .  "\n";
                }

                # Then the message
                my $comment_line = '# ';
                if ($xpath->exists('/config/file/comment_line'))
                {
                	$comment_line = $xpath->getNodeText('/config/file/comment_line');
                }
                elsif ($defaults_xpath->exists('/config/file/comment_line'))
                {
                        $comment_line = $defaults_xpath->getNodeText('/config/file/comment_line');
                }

                if (! File::Spec->file_name_is_absolute($warning_file))
                {
                	$warning_file = File::Spec->canonpath("$CONFIGBASE/$warning_file");
                }
                open(WF, '<', $warning_file) || &away("open of warning file $warning_file:  $!\n");
                while(<WF>) { $message .= $comment_line . $_; }
                close(WF);

                # And last the comment closer
                my $comment_close = '';
                if ($xpath->exists('/config/file/comment_close'))
                {
                        $comment_close = $xpath->getNodeText('/config/file/comment_close');
                }
                elsif ($defaults_xpath->exists('/config/file/comment_close'))
                {
                        $comment_close = $defaults_xpath->getNodeText('/config/file/comment_close');
                }
                if ($comment_close)
                {
                        $message .= $comment_close .  "\n";
                }

                if (! $xpath->exists('/config/file/warning_on_second_line'))
                {
                        $newcontents = $message . "\n" . $newcontents;
                }
                else
                {
                        my ($firstline, $rest) = split(/\n/, $newcontents, 2);
                        $newcontents = $firstline . "\n\n" . $message . "\n" . $rest;
                }
	}

        # Proceed if:
        # - The new contents are different from the current file
        # - The permissions or ownership requested don't match the
        #   current permissions or ownership
        unless (
        	compare_file_contents($file, $newcontents) ||
                compare_permissions($file, $perms) ||
                compare_ownership($file, $uid, $gid))
        {
                &log("\tno change necessary\n", $debug);
		return(1);
        }

        if (-d $file && ! -l $file)
        {
        	# Check for force, force will wipe up directory if it exists
                &away("Original of $file is a directory\n") if (! $xpath->exists('/config/file/force') );
                &remove_file($file);
        }

        # Perform any pre-action commands that the user has requested
        &process_pre($file, $xpath, $dryrun);

        # Save the original file
        copy_original($file, 1, $dryrun);

        # If the new contents are different from the current file,
        # replace the file.
        if (compare_file_contents($file, $newcontents))
        {
        	if ($dryrun)
                {
                	print "Generated contents for $file:\n";
                       	print "=================================================\n";
                       	print $newcontents;
                       	print "=================================================\n";
		}
        	else
        	{
        		&display("Writing out new $file\n");
	
                	# Write out the file using a .new filename
                	open(FILE, '>', "$file.new") || &away("open $file.new:  $!\n");
                	print FILE $newcontents;
                	close(FILE);

	                # If the old file is not a plain file, remove it
                	remove_file($file) if (-l $file || ! -f $file);

                	# Move the new file into place
                	rename("$file.new", $file) || &away("rename $file.new -> $file:  $!");
		}
        }

        # Ensure the permissions are set properly
        &chmod($perms, $file, $debug);

        # Ensure the ownership is set properly
        &chown($uid, $gid, $file, $debug);

        # Perform any post-action commands that the user has requested
        &process_post($file, $xpath, $dryrun);

	return(1);
}

sub generate_link($$$)
{
	my ($file, $xpath, $dryrun) = @_;

        my $dest;

	my $mine;
        if (&ismine('/config/link/dest', $xpath) && $dryrun != 9)
        {
		eval { &process_depend($file, $xpath, $dryrun); };
		&perminfo($file, $xpath, 'link');
		&makepath($file, $dryrun, '0755');
		&process_setup($file, $xpath, $dryrun);

        	my @destnodes = $xpath->findnodes('/config/link/dest');
                &check_for_inconsistency($file, @destnodes);
                $dest = $destnodes[0]->string_value;
        }
        elsif (&ismine('/config/link/script', $xpath) && $dryrun != 9)
        {
		eval { &process_depend($file, $xpath, $dryrun); };
		&perminfo($file, $xpath, 'link');
		&makepath($file, $dryrun, '0755');
                &process_setup($file, $xpath, $dryrun);

        	# The user can specify a script to perform more complex
                # testing to decide whether to create the link or not and
                # what its destination should be.
                $dest = &process_script('link', $file, $xpath);
        }
        else
        {
                # If the filtering has removed the destination for the link,
                # that means it doesn't apply to this host.
                &log("\tNo destination for $file link, doing nothing\n", 7) if ($dryrun != 9);
		return(0);
        }

        if ($test)
        {
                # we need to inform above that we need to proceed with runas
                if (defined $test && $test)
                {
                        @{$GENERATETEST{'generate_link'}} = ($file, $xpath, $dryrun, 0);
                        return(1);
                }
        }
        &log("Generating $file (LINK)\n", $debug);

        # Proceed if:
        # - The new link destination differs from the current one
        unless (compare_link_destination($file, $dest))
        {
	        &log("\tno change necessary\n", $debug);
		return(1);
        }

        if (-d $file && ! -l $file)
        {
        	# Check for force, force will wipe up directory if it exists
                &away("Original of $file is a directory\n") if (! $xpath->exists('/config/link/force') );
                &remove_file($file);
        }

        # Perform any pre-action commands that the user has requested
        &process_pre($file, $xpath, $dryrun);

        # Save the original file
        &copy_original($file, 1, $dryrun);

        # Create the link
        &symlink($dest, $file);

        # Ensure the ownership is set properly
        &chown($uid, $gid, $file, $debug) if (!$dryrun);

        # Perform any post-action commands that the user has requested
        &process_post($file, $xpath, $dryrun);

	return(1);
}

sub generate_directory($$$$)
{
	my ($file, $xpath, $dryrun, $test) = @_;

	if (&ismine('/config/directory/perms_only', $xpath) && $dryrun != 9)
        {
		eval { &process_depend($file, $xpath, $dryrun); };
		&perminfo($file, $xpath, 'directory');
		&makepath($file, $dryrun, '0755');
        	&process_setup($file, $xpath, $dryrun);

                # perms only
                &log("Permission change only\n", $debug);
                unless ( compare_permissions($file, $perms) || compare_ownership($file, $uid, $gid) )
                {
                        &log("\tno permissions change necessary\n", $debug);
                        return(1);
                }

                # Ensure the permissions are set properly                                                                                                     
                &chmod($perms, $file, $debug);

                # Ensure the ownership is set properly                                                                                                        
                &chown($uid, $gid, $file, $debug);
                return(0);
        }

        # If the filtering has removed the directive to create this
        # directory, that means it doesn't apply to this host.
	if ( ! &ismine('/config/directory/create', $xpath) && ! &ismine('/config/directory/script', $xpath) && ! &ismine('/config/directory/rsync', $xpath) )
        {
        	&log("\tNo directive to create $file directory, doing nothing\n", 7) if ($dryrun != 9);
		return(0);
        }
	return(0) if ($dryrun == 9); 

	eval { &process_depend($file, $xpath, $dryrun); };
	&perminfo($file, $xpath, 'directory');
	&makepath($file, $dryrun, '0755');
        &process_setup($file, $xpath, $dryrun);

        if ($test)
        {
                # we need to inform above that we need to proceed with runas
                if (defined $test && $test)
                {
                        @{$GENERATETEST{'generate_directory'}} = ($file, $xpath, $dryrun, 0);
                        return(1);
                }
        }
        &log("Generating $file (DIRECTORY)\n", $debug);


        # The user can specify a script to perform more complex testing
        # to decide whether to create the directory or not.
        # if $script returns true, then script modified something
        my $script = &process_script('directory', $file, $xpath);

        # The user can specify an rsync from where to copy
        my $rsync = &process_rsync('directory', $file, $xpath, $dryrun);

        # Proceed if:
        # - The current file is not a directory
        # - The permissions or ownership requested don't match the
        #   current permissions or ownership
        unless (
        	! -d $file ||
                compare_permissions($file, $perms) ||
                compare_ownership($file, $uid, $gid) || 
                $script || $rsync )
        {
        	&log("\tno change necessary\n", $debug);
		return(1);
        }

        # Perform any pre-action commands that the user has requested
        &process_pre($file, $xpath, $dryrun);

        # Save the original file
        copy_original($file, 0, $dryrun);

        # Create the directory
        if (! -d $file)
        {
        	&display("Making directory $file\n");
                if (!$dryrun)
                {
                	remove_file($file);
                        mkdir($file);
                }
        }

        # Ensure the permissions are set properly
        &chmod($perms, $file, $debug);

        # Ensure the ownership is set properly
        &chown($uid, $gid, $file, $debug);

        # Perform any post-action commands that the user has requested
        &process_post($file, $xpath, $dryrun);

	return(1);
}

sub generate_delete($$$$)
{
	my ($file, $xpath, $dryrun, $test) = @_;

        my $proceed=0;
        if (&ismine('/config/delete/script', $xpath) && $dryrun != 9)
        {
		eval { &process_depend($file, $xpath, $dryrun); };
        	&process_setup($file, $xpath, $dryrun);

        	# The user can specify a script to perform more complex
                # testing to decide whether to delete or not
                $proceed = &process_script('delete', $file, $xpath);
        }
        elsif (&ismine('/config/delete/proceed', $xpath) && $dryrun != 9)
        {
		eval { &process_depend($file, $xpath, $dryrun); };
        	&process_setup($file, $xpath, $dryrun);

                $proceed = 1 if (-e $file);
        }
        else
        {
                &log("\tNo directive to delete $file, doing nothing\n", 7) if ($dryrun != 9);
		return(0);
        }
        &log("Generating $file (DELETE)\n", $debug);

        if ($proceed || ! -e $file)
        {
        	&log("\tno change necessary\n", $debug);
		return(1);
        }

        if (-d $file && ! -l $file)
        {
	        # Check for force, force will wipe up directory if it exists
                &away("Original of $file is a directory\n") if (! $xpath->exists('/config/delete/force') );
                &remove_file($file);
        }

        # Save the original file
        copy_original($file, 1, $dryrun);

        # Perform any pre-action commands that the user has requested
        &process_pre($file, $xpath, $dryrun);

        &display("Removing $file\n");
        remove_file($file) if (!$dryrun);

        # Perform any post-action commands that the user has requested
        &process_post($file, $xpath, $dryrun);

	return(1);
}

# Create symlink
sub symlink($$)
{
	my ($file, $dest) = @_;
	&bug("Incorrect params") if (! defined $file || ! defined $dest);
        if ( compare_link_destination($dest, $file) )
        {
                &display("Linking $dest -> $file\n");
		if (!$dryrun)
		{
                	&remove_file($dest);
			symlink($file, $dest);
		}
		return(1);
	}
	return(0);
}

# read file and return as variable
sub readfile
{
	my( $file_name, %args ) = @_ ;
        my $buf ;
        my $buf_ref = $args{'buf_ref'} || \$buf ;
        my $mode = O_RDONLY ;
        $mode |= O_BINARY if $args{'binmode'} ;
        local( *FH ) ;
        sysopen( FH, $file_name, $mode ) or &bug("Can't open $file_name: $!");
        my $size_left = -s FH ;
        while( $size_left > 0 ) 
	{
        	my $read_cnt = sysread( FH, ${$buf_ref}, $size_left, length ${$buf_ref} );
                unless( $read_cnt ) 
		{
                	&bug("read error in file $file_name: $!");
                }
                $size_left -= $read_cnt ;
        }
        # handle void context (return scalar by buffer reference)
        return unless defined wantarray ;
        # handle list context
        return split m|?<$/|g, ${$buf_ref} if wantarray ;
        # handle scalar context
        return ${$buf_ref} ;
}

# Sets file file, directory, and symlink ownership
# returns 1 for success, 0 otherwise
sub chown($$$$)
{
        my ($uid, $gid, $file, $debug) = @_;
        &bug("incorrect params") if (! defined $uid || ! defined $gid || ! defined $file);

        sub chownfile
        {
                my $uid = shift;
                my $gid = shift;
                my $debug = shift;
                my $f = shift || $_;
                return unless (compare_ownership($f, $uid, $gid));
                &log("Setting ownership of $f to $uid:$gid\n", $debug);
                if (!$dryrun)
                {
			if (-l $f)
			{
                        	system( ("/usr/bin/chown", "-h", "$uid:$gid", "$f") ) ;
				if ( $? != 0 ) { &away("Unable to chown $f to $uid:$gid");}
			}
			else
			{
                        	chown($uid, $gid, $f) || &away("Unable to chown $f to $uid:$gid");
			}
			return;
                }
        }
        if ($rowner && $rgroup)
        {
                return find( { wanted => sub { &chownfile($uid, $gid, $debug) } }, $file);
        }
        elsif ($rowner || $rgroup)
        {
                find( { wanted => sub { &chownfile($uid, -1, $debug) } }, $file) if ($rowner);
                find( { wanted => sub { &chownfile(-1, $gid, $debug) } }, $file) if ($rgroup);
        }
        &chownfile($uid, $gid, $debug, $file);
}

# Sets permission for file
sub chmod
{
        my ($perms, $file, $debug) = @_;
        &bug("incorrect params") if (! defined $perms || ! defined $file);

        my $o = octify($perms);

        sub chmodfile
        {
                my $perms = shift;
                my $o = shift;
                my $debug = shift;
                my $f = shift || $_;
                return unless (compare_permissions($f, $perms));
                &log("Setting permissions on $f to $perms\n", $debug) if ($f !~ /\.LOCK$/);
		if (!$dryrun)
		{
                	CORE::chmod($o, $f) || &away("Unable to set permission on $f to $perms");
		}
                return(1);
        }
        return find( { wanted => sub { &chmodfile($perms, $o, $debug) } }, $file) if ($rperms);
        return &chmodfile($perms, $o, $debug, $file);
}

# Gets permission information
sub perminfo($$)
{
        my ($file, $xpath, $type) = @_;
        our ($perms, $rperms, $rowner, $rgroup) = ('0644', 0, 0, 0);
	our $owner = $owner || $SYSTEMOWNER;
        our $group = $group || $SYSTEMGROUP;
	
	# %perminfo holds permission history
	our %perminfo if (!defined %perminfo);
	my $f;
	my @path = map { $f .= "$_/"; } split(/\//, $file);
	for (my $i=$#path; $i > 0; $i--)
	{
		chop($path[$i]);
		my $p = $path[$i];
		next if (! exists $perminfo{$p});
		$perms = $perminfo{$p}{'perms'}; $rperms = $perminfo{$p}{'rperms'};
		$owner = $perminfo{$p}{'owner'}; $rowner = $perminfo{$p}{'rowner'};
		$group = $perminfo{$p}{'group'}; $rowner = $perminfo{$p}{'rgroup'};
		last;
	}

        my $p = $xpath->findnodes("/config/$type/perms") || $defaults_xpath->findnodes("/config/$type/perms");
        my $o = $xpath->findnodes("/config/$type/owner") || $defaults_xpath->findnodes("/config/$type/owner");
        my $g = $xpath->findnodes("/config/$type/group") || $defaults_xpath->findnodes("/config/$type/group");
        if ($p->[0])
        {
                $perms = $p->[0]->string_value;
                $rperms = 1 if ($p->[0]->getAttribute('recursive'));
        }
        if ($o->[0])
        {
                $owner = $o->[0]->string_value;
                $rowner = 1 if ($o->[0]->getAttribute('recursive'));
        }
        if ($g->[0])
        {
                $group = $g->[0]->string_value;
                $rgroup = 1 if ($g->[0]->getAttribute('recursive'));
        }
        our $uid = lookup_uid($owner);
        our $gid = lookup_gid($group);

	# save history
	%{$perminfo{$file}} = ( 'owner' => $owner, 'group' => $group, 'perms' => $perms, 'rperms' => $rperms, 
			     'group' => $group, 'rgroup' => $rgroup, 'uid' => $uid, 'gid' => $gid );
}

# Sets path for file, prepares for mkpath()
sub makepath
{
        my $file = shift || $file;
        my $dryrun = shift;
        my $perms = shift || $perms;
	my $uid = shift || $uid;
	my $gid = shift || $gid;	
        my $filedir = dirname $file;
        if (! -d $filedir)
        {
                &log("Making directory tree $filedir: $perms\n", 7);
                unless ($dryrun)
                {
                        my $umask = umask 0 if ($perms);
			File::Path::mkpath($filedir, ($debug > 8?'1':0), &octify($perms)) || &bug("Unable to mkpath($filedir)\n");
                        umask $umask if ($perms);
                }
        }
}

# Used when parsing each config.xml to filter out any elements which
# don't match the configuration of this host.
sub check_attributes
{
	my $twig = shift;
	my $element = shift;

	my %atts = %{$element->atts};
	foreach my $key (keys %atts)
	{
	        foreach my $val (split(/\s+/, $atts{$key}))
		{
			my ($negate, $found) = (0, 1);
			if ($val =~ /^!/) { $negate = 1; $val =~ s/^!//; }

			if ($key eq 'arch')
			{
				if ($negate)    { $found = 0 if ($ARCH =~ /^$val$/); }
                                else            { $found = 0 if ($ARCH !~ /^$val$/); }
			}
			elsif ($key eq 'fullarch')
                        {
                                if ($negate)    { $found = 0 if ($FULLARCH =~ /^$val$/); }
                                else            { $found = 0 if ($FULLARCH !~ /^$val$/); }
                        }
			elsif ($key eq 'os')
			{
				if ($negate)	{ $found = 0 if ($OS =~ /^$val$/); }
				else		{ $found = 0 if ($OS !~ /^$val$/); }
			}
			elsif ($key eq 'osversion')
			{
				if ($negate) 	{ $found = 0 if ($OSVERSION =~ /^$val$/); }
				else		{ $found = 0 if ($OSVERSION !~ /^$val$/); }
			}
			elsif ($key eq 'hostname')
			{
				if ($negate)	{ $found = 0 if ($HOSTNAME =~ /^$val$/); }	
				else		{ $found = 0 if ($HOSTNAME !~ /^$val$/); }
			}
			elsif ($key eq 'linuxdistro')
			{
				if ($negate)	{ $found = 0 if ( $LINUXDISTRO =~ /^$val$/ ); }
				else		{ $found = 0 if ( $LINUXDISTRO !~ /^$val$/ ); }
			}
			elsif ($key eq 'linuxdistroversion')
			{
				if ($negate) 	{ $found = 0 if ($LINUXDISTROVERSION =~ /^$val$/ ); }
				else		{ $found = 0 if ($LINUXDISTROVERSION !~ /^$val$/ ); }
			}
                        elsif ($key eq 'duty')
                        {
				if ($negate) 	{ $found = 0 if (   grep { /^$val$/ } @DUTIES ); }
				else	     	{ $found = 0 if ( ! grep { /^$val$/ } @DUTIES ); }
                        }
                        elsif ($key eq 'hardware')
                        {
				if ($negate)	{ $found = 0 if (   grep { /^$val$/ } @HARDWARE ); }	
                                else		{ $found = 0 if ( ! grep { /^$val$/ } @HARDWARE ); }
                        }
			elsif ($key eq 'cluster')
                        {
                                if ($negate)    { $found = 0 if (   grep { /^$val$/ } @CLUSTERS ); }
                                else            { $found = 0 if ( ! grep { /^$val$/ } @CLUSTERS ); }
                        }
			elsif ($key eq 'location')
                        {
                                if ($negate)    { $found = 0 if (   grep { /^$val$/ } @LOCATION ); }
                                else            { $found = 0 if ( ! grep { /^$val$/ } @LOCATION ); }
                        }

			if (!$found)
			{
				# If we are here that means we are not matched
				$element->cut;
				last;
			}
		}
	}
}
# used in similar fashion as check_attributes, except this is to be called from generate_ functions
# came from MANUALDUTIES req
# arg: (string)dst $xpath
# returns true or false
sub ismine
{
	my $dst = shift;	
	my $xpath = shift;
	my $msg = shift || "START Etching $FILE ". ($dryrun?'(DRYRUN)':'') ."\n";
	our $ISMINE if (!defined $ISMINE);
	$ISMINE='';
	&log("Processing $FILE ". ($dryrun?'(DRYRUN)':''), 7 );
	my @nodes;
	my @matched;
	if (@nodes = $xpath->findnodes($dst))
	{	
		@matched=@nodes;
		if (@MANUALDUTIES)
		{
			my $key = 'duty';
			my @duties;
			@matched=();
			foreach my $node ( @nodes )
			{
				my @d = split(/\s+/, $node->getAttribute($key));
				push(@duties, @d);
				foreach my $val ( @d )
				{
					push(@matched, $node) if ( grep { $_ =~ /^$val$/ } @MANUALDUTIES );
				}
			}
			if (!@matched)
			{
				&log("\tManual dut". ($#MANUALDUTIES?"ies":"y") ." '". join(',', @MANUALDUTIES) ."' specified but not matched" .(@duties?" to '".join(',', @duties)."'":""). ".", 7);
			}
		}

		if (@matched)
		{
			if ($dryrun != 9)
                	{
                        	&log($msg);
                        	&logprepush();
                	}
			$ISMINE=$FILE;
			if ($debug > 8) { map { &log("NODE MATCH: " . $_->toString) } @matched; }
			elsif ($dryrun == 9)
			{
				map { print "$FILE - NODE MATCH: ". $_->toString ."\n" } @matched if ($debug > 8 || $dryrun == 9);
			}
			return(1);
		}
	}
	return(0);	
}

sub check_for_inconsistency
{
	my ($file, @nodes) = @_;

	my $first_node_text = $nodes[0]->string_value;
	# first_node_text takes precedence

	#foreach my $node_text (map { $_->string_value } @nodes)
	#{
	#	&away("Inconsistent entry for $file\n") if ($node_text ne $first_node_text);
	#}
	return 0;
}

# Returns true if the new contents are different from the current file,
# or if the file does not currently exist.
sub compare_file_contents
{
	my $file = shift || &bug("No file received");
	my $newcontents = shift;  # Can be an empty string
	&bug("Undefined newcontents received") if (! defined $newcontents);

	my $r = 0;

	# If the file currently exists and is a regular file, check to see
	# if the new contents are different.
	if (-f $file)
	{
		my $contents = '';
		open(FILE, '<', $file) || &away("unable to open current file $file:  $!\n");
		while(<FILE>)
		{
			$contents .= $_;
		}
		close(FILE);

		if ($newcontents ne $contents)
		{
			$r = 1;
		}
	}
	else
	{
		# The file doesn't currently exist or isn't a regular file
		$r = 1;
	}

	return $r;
}

# Returns true if the new link destination is different from the current
# link, or if the link does not currently exist.
sub compare_link_destination
{
	my $dest = shift || &bug("No dest received");
	my $file = shift || &bug("No file received");

	my $r = 0;

	# If the file currently exists and is a link, check to see if the
	# new destination is different.
	if (-l $dest)
	{
		my $currentdest = readlink($dest);
		if ($currentdest ne $file)
		{
			$r = 1;
		}
	}
	else
	{
		# The file doesn't currently exist or isn't a link
		$r = 1;
	}

	return $r;
}

sub copy_original
{
        my $file = shift || &bug("No copy_original_file received");
        my $save_directory_contents = shift;  # Can be false
        my $dryrun = shift;  # Can be false
        return if ($dryrun);

        my $savepath = File::Spec->canonpath("$ORIGBASE/$file");

        # If the original has already been saved, we don't need to do anything
        if (-e $savepath || -e "$savepath.NOORIG" || -e "$savepath.tar")
        {
                &log("Original file already saved:  $file\n", 7);
                return;
        }

        # Make sure the directory tree for this file exists in the
        # directory we save originals in.
        &makepath($savepath, 0, "0777");

        # If the original doesn't exist, we need to flag that so that we
        # don't try to save our generated file as an original on future
        # runs
        if (! -e $file)
        {
                &display("Original file doesn't exist:  $file\n");
                if (!$dryrun)
                {
                        open(NO, '>', "$savepath.NOORIG") || &away("unable to write $savepath.NOORIG:  $!");
                        close(NO);
                }
                return;
        }

        # Now copy the original file

        if (-d $file)
        {
                if ($save_directory_contents)
                {
                        # Tar up the original directory
                        my $filedir = dirname $file;
                        my $filebase = basename $file;
                        &display("Saving contents of original directory $file\n");
                        system("cd $filedir && tar cf $savepath.tar $filebase") if (! $dryrun);
                }
                else
                {
                        # Just create a directory in the originals repository with
                        # ownership and permissions to match the original directory.
                        my $st = lstat($file) || &away("unable to stat $file: $!\n");
                        &chown($st->uid, $st->gid, $savepath, 0);
                        &chmod(&uoctify($st->mode), $savepath, 0);
                }
        }
        else
        {
                # Note that cp -p will follow symlinks.  GNU cp has a -d option
                # to prevent that, but Solaris cp does not, so we resort to
                # cpio.
                &display("Saving original file:  $file -> $savepath\n");
                #system("cp -p $file $savepath") if (! $dryrun);
		my $output = `find $file | cpio -pdum $ORIGBASE 2>&1` if (! $dryrun);
		chomp($output);
		&display("Saving original file:  $file -> $savepath ($output)\n");	
        }
}

# Perform any setup commands that the user has requested.
# These are occasionally needed to install software that is
# required to generate the file (think m4 for sendmail.cf) or to
# install a package containing a sample config file which we
# then edit with a script, and thus doing the install in <pre>
# is too late.
sub process_setup
{
	my ($file, $xpath, $dryrun) = @_;
	return if ( ! $xpath->exists("/config/setup") );

	# Because the setup commands are processed every time (rather than
	# just when the file has changed as with pre/post) we don't want to
	# print a message for them.
	&log("Processing setup commands\n", 7);
	&process_command('setup', @_);
	&process_rsync('setup', @_);
}
sub process_pre
{
        my ($file, $xpath, $dryrun) = @_;
	return if ( ! $xpath->exists("/config/pre") );

	&log("Processing pre-action commands\n", 7);
	&process_command('pre', @_);
	&process_rsync('pre', @_);
}
sub process_post
{
        my ($file, $xpath, $dryrun) = @_;
	return if ( ! $xpath->exists("/config/post") );

	&log("Processing post-action commands\n", 7);
	&process_command('post', @_);
	&process_rsync('post', @_);
}

# used for template purpose as well
sub process_script
{
	my ($when, $file, $xpath, $dryrun) = @_;

	my ($script, $scriptArg, $newcontents);
	
	if ($when =~ /^::ETCH:(.*?)\((.*?)\)::$/)
	{
		#template mode, if generate_file is calling process_script
		($script, $scriptArg) = ($1, $2);
		&log("Processing template $script($scriptArg) for $file\n", 4);	
		$script = "$CONFIGBASE/templates/$script";
	}
	elsif ( $xpath->exists("/config/$when/script") )
	{
		# regular script
		return if ( ! $xpath->exists("/config/$when/script") );
		&log("Processing $when/script for $file\n", 4);

		my @nodes = $xpath->findnodes("/config/$when/script");
		&check_for_inconsistency($file, @nodes);

		$script = $nodes[0]->string_value;
		# use common script if common is enabled
        	$script = "$CONFIGBASE/scripts/$script" if ($nodes[0]->getAttribute('common') eq 'true');
        	$scriptArg = $nodes[0]->getAttribute('arg');
	}
	else
	{
		return;
	}

        # Create a new Safe compartment to run the script in
        my $compartment = new Safe;

        # Perl 5.8 has a nice alternative to using a pipe and
        # forking, you can open an in-memory filehandle that goes
        # directly to a scalar variable.  Alas, we can't expect
        # everybody to have Perl 5.8.

        # Open a pipe that we'll use to read the new file contents
        # from the script
        pipe(CONFIG_RDR, CONFIG);

        # 'our' instead of 'my' declaration on $FILE and
        # $ORIGINAL_FILE so that they can be shared with the Safe
        # compartment.

        our $FILE = $file;
	our $FILEBASE = basename($file);
        our $DIR = dirname($FILE);
        our $ORIGINAL_FILE;
        if (-e "$ORIGBASE/$file")
        {
        	$ORIGINAL_FILE = File::Spec->canonpath("$ORIGBASE/$file");
        }
        else
        {
                $ORIGINAL_FILE = $file;
        }

        # Share the system variables
        $compartment->share(@SAFESHARE);

        # Prevent the script from doing a few things it shouldn't or
        # that would cause us problems.  It shouldn't try to do so
        # anyway, but we all make mistakes.  This isn't meant to be
        # bullet-proof, we generally trust the source of the script.
        # We just want to try to prevent mistakes from causing harm.
        #$compartment->deny_only(':filesys_write', 'chdir', ':dangerous');
        $compartment->deny_only('chdir', ':dangerous');

        # Fork and execute the script
        # The fork is necessary because the kernel will generally
        # not buffer an unlimited amount of data in a pipe.

        my $pid = fork;
        if ($pid)  # Parent
        {
        	# Close the end of the pipe that the parent doesn't use
                close(CONFIG);

                # Read in the new contents from the pipe
                $newcontents = join('', <CONFIG_RDR>);
                close(CONFIG_RDR);

                # And reap the child process
                waitpid($pid, 0);
		
                # Abort if the child process exited with error (which
                # indicates that executing the script failed).
                &away("Script failed: $file => $script") if ($?);
        }
        elsif (defined $pid)  # Child
        {
                # Close the end of the pipe that the child doesn't use
                close(CONFIG_RDR);

                # rdo won't complain if the script doesn't exist, so
                # check for that
                &away("Script $file => $script doesn't exist\n") if (! -f $script);

                # "Execute" the script
		our $ARG = $scriptArg;
		our @ARGS = split(',', $scriptArg);
                $compartment->rdo($script);

                # We can't really depend on the return value from rdo(),
                # as the script isn't really executed but more like
                # eval'd.  So use the eval'ish behavior of checking $@.
                &away("Error executing script for $file: $@") if ($@);

                close(CONFIG);

                exit;
	}
        else  # Failure
        {
        	&away("fork failed for: $file => $script: $!");
        }

	return($newcontents);
}

sub process_rsync($$)
{
        my $when = shift || &bug("No setup/pre/post received");
        my $file = shift || &bug("No file received");
        my $xpath = shift || &bug("No xpath received");
        my $dryrun = shift;  # Can be false
	my $process_options = shift; # used for process information

	return(0) if (! $xpath->exists("/config/$when/rsync") );

	my @nodes = $xpath->findnodes("/config/$when/rsync");
	my $node = $nodes[0];
	return(0) if (! $node);
	my $string = $node->string_value;	

	# eval $src just in case we want to use a variable
	# Use autogen depot if rsync src is empty
	my $src = eval "\"$string\"";
	$src = $RSYNC_SRC . $src if ($src =~ /^::/ && $RSYNC_SRC);
	if (!$src)
	{
		if ($RSYNC_SRC)
		{	
			$src = "${RSYNC_SRC}::";
			if ($options && exists $options->{process} && exists $options->{parent})
			{
				$src .= basename($options->{parent});
			}
			else
			{
				$src .= basename($file) . "/";
			}
			&log("Rsync src path is empty, using default: $src\n", 4);
		}
		else
		{
			&away("Rsync src path is empty: $string for $file");
		}
	}

	my ($dst, $altdst, $command, $options, $exclude, $excludefrom);
	my $manual = 0;
	foreach my $attribute ($node->getAttributes())
	{
		my ($key, $val) = ($attribute->getName, $attribute->getData);
		if ($key eq 'exclude-from') { $excludefrom = $val; }
		elsif ($key eq 'exclude') { $exclude = $val; }
		elsif ($key eq 'command') { $command = $val; }
		elsif ($key eq 'options') { $options = $val; }
		elsif ($key eq 'dest')    { $altdst = $dst = $val;    }
		elsif ($key eq 'manual')  { $manual = $val; }
	}

	if ($manual && ! grep { /^$file/ } @manualfilesOriginal )
	{
		&log("Manual attribute set, not processing rsync because its not invoked manually.", 4);
		return;
	}
	
	$dst = $file if (!$dst);
	$command = $defaults_xpath->getNodeText("/config/rsync/command") if (!$command);
	$options = $defaults_xpath->getNodeText("/config/rsync/options") if (!$options);
	$exclude = $defaults_xpath->getNodeText("/config/rsync/exclude") if (!$exclude);
	$options .= " --exclude='${exclude}'" if ($exclude);
	$options .= " --exclude-from=${excludefrom}" if ($excludefrom);
        $options .= " --dry-run" if ($dryrun);
	$options .= " -v";

	# generate rsync options from --exclude/--include
	$options .= " ". join(" ", map { "--include=\"$_\"" } @INCLUDES) if (@INCLUDES);
	$options .= " ". join(" ", map { "--exclude=\"$_\"" } @EXCLUDES) if (@EXCLUDES);

	# process mode via rsync, update src to include subdirectories from $dst
	my $doProcess=0;
	if ($process_options && !$altdst && exists $process_options->{process} && $process_options->{parent} ne $dst)
	{
		if ($altdst) 
		{ 
			&log("Not processing subdirectory rsync because 'dest: $altdst' key exists in config"); 
			return;
		}
		my $parent = $process_options->{parent};
		my $subdir = $dst;
		$subdir =~ s/^$parent//;
		$src .= "/$subdir/";
		$doProcess=1;
		chdir "$SOURCEBASE/$parent" || &away("chdir to $SOURCEBASE/$parent:  $!\n");
	}

	# prepare src and dst
	while ($src =~ /(.*?)\/$/) { $src = $1;}
	while ($dst =~ /(.*?)\/$/) { $dst = $1;}
	$src .= "/";
        $dst .= "/";
	
	# get rid of duplicate //
	while ($src =~ /\/\//) { $src =~ s/\/\//\//g;}
	while ($dst =~ /\/\//) { $dst =~ s/\/\//\//g;}

	# if in process mode and we are processing file, then chop off trailing /
	# @TODO: come up with a cleaner way to differentiate between file and directory $dst
	if ( $doProcess )
	{
		my $loc = $dst;
		$loc =~ /(.*?)\/$/; $loc = $1;
		if ( -f $loc || -l $loc )
		{
			$dst = $loc;
			$src =~ s/\/$//;
			&log("Detected destination as file type, modifying src/dst to only process file", 8);
		}
		elsif ( -d $loc )
		{
			&log("Detected destination as directory type, modifying src/dst to process directory", 8);
		}
		else
		{
			&log("Unable to determine destination type, assuming src/dst to be directory", 8); 
		}
		
	}

	my $cmd = "$command $options $src $dst";
	&log("RSYNC: $cmd\n", $debug);
        my $pid = open(CMD, "$cmd 2>&1 |") or &away("Couldnt run rsync for $file: $!\n");
	my (@errors, $errorfound, $successfound);
	my $start=0;
        while(<CMD>)
        {
		if (!$start) { $start=1; &log($DIV, $debug); }
		next if (/^\s/);
		$errorfound = 1 if (/rsync error:/);
		$successfound = 1 if (/\d+\s+speedup/);
		if ( $errorfound ) { &display("COLOR:red:$)"); }	
		elsif (/^receiving.*?list/)
		{
			next;	
			#&log($DIV, 4);
			#&log("rsync($src, $dst): $_", 4); 
		}
		elsif (/^(sent \d|total size is)/)
		{
			if ($errorfound) { &display("COLOR:red:$_"); }
			else { &display("COLOR:yellow:$_"); }
		}
		else { &display("rsync($src, $dst): $_"); }
		push(@errors, $_); 
		shift(@errors) if ($#errors > 10);
        }
        close(CMD);
	&log($DIV, $debug) if ($start == 1);

	if ($errorfound || !$successfound)
	{
		&log("ERRORS FOUND! $errorfound : $successfound $file => rsync($src, $dst)\n");
		&log($DIV);
        	map { &log("$_") } @errors;
		&log($DIV);
		&quit();
	}

	return(1);
}

sub process_command
{
	my $when = shift || &bug("No setup/pre/post received");
	my $file = shift || &bug("No file received");
	my $xpath = shift || &bug("No xpath received");
	my $dryrun = shift;  # Can be false

	if ($xpath->exists("/config/$when/exec"))
	{
		my @execnodes = $xpath->findnodes("/config/$when/exec");

		foreach my $exec (map { $_->string_value } @execnodes)
		{
			&log("Executing '$exec'\n",$debug);
			&log($DIV, $debug);
			my $r = system($exec) if (! $dryrun);

			if ($r)
			{
				# We don't normally print the command we're executing
				# for setup commands (see above).  But that makes it
				# hard to figure out what's going on if it fails.  So
				# include the command in the message if there was a
				# failure.
				my $execmsg = '';
				$execmsg = "'$exec' " if ($when eq 'setup');

				&away("    Setup/Pre/Post command $execmsg, for $file exited with non-zero value\n");
			}
			&log($DIV, $debug);
		}
	}
}

sub process_depend
{
        my $file = shift || &bug("BUG:  No file received");
        my $xpath = shift || &bug("BUG:  No xpath received");
	my $dryrun = shift;

	return if ( ! $xpath->exists("/config/depend") );

	if ($xpath->exists("/config/depend/dest"))
	{
		my @dest = $xpath->findnodes("/config/depend/dest");
		&log("-Dependencies found---------------\n", $debug);
		foreach my $dep (map { $_->string_value } @dest)
		{
			# enable relative path
			$dep = dirname($file) ."/". $dep if ($dep !~ /^\//);

			&log("Processing dependency $dep\n", $debug);
			my $pid;
			pipe(PIPC, IPC);
			unless($pid = fork())
			{
				&logprepush();
				close(PIPC);
				our $CHILD=1;
				# override manualfile otherwise generateall will ignore when in manualmode, safe since we are in a fork
				$manualfile=$dep;
				&generateall($dep, $file, $dryrun);	
				close(IPC);
				exit;
			}
			close(IPC);
			
			my $done = 0;
			my $error = 0;
			while(<PIPC>)
			{
				if    (/^GENERATED:(.*?):DONE/) { $GENERATED{$1} = $done = 1; }
				elsif (/^GENERATED:(.*)/) { $done = 0; }
				elsif (/^ERROR/) { $error = 1; }
			}	
			close(PIPC);

			waitpid($pid, 0);

			# Check if anything has failed
			&away("ERROR detected in dependencies\n") if ($error);
		}
		&log("-End of dependencies for $file\n", $debug);
	}
}


sub lookup_uid
{
	my $owner = shift;  # Can be zero
	&bug("No owner received") if (! defined $owner);

        # Caching function for getpwnam
        sub getpwnamC
        {
		my $o = shift;
                our %getpwnamC if (!defined %getpwnamC);
                return $getpwnamC{$o} if (exists $getpwnamC{$o});

		my $i = getpwnam($o);
		if (! defined $i)
		{
			&log("config.xml requests user $o, but that user can't be found.  Using UID $SYSTEMUID.\n"); 
			return $SYSTEMUID;
		}
		$getpwnamC{$o} = $i;
                return $getpwnamC{$o};
        }

	my $uid;
	if ($owner =~ /^(\d+)$/)
	{
		$uid = int $1;
	}
	else
	{
		# Otherwise attempt to look up the username to get a UID.
		# Default to UID 0 if the username can't be found.
		$uid = &getpwnamC($owner);
	}

	return $uid;
}

sub lookup_gid
{
	my $group = shift;  # Can be zero
	&bug("No group received") if (! defined $group);

	# Caching function for getgrnam
	sub getgrnamC
	{
		my $g = shift;
		our %getgrnamC if (!defined %getgrnamC);
		return $getgrnamC{$g} if (exists $getgrnamC{$g});

		my $i = getgrnam($g);
		if (! defined $g)
		{	
			&log("config.xml requests group $g, but that group can't be found. Using GID $SYSTEMGID.\n"); 
			return $SYSTEMGID;
		}
		$getgrnamC{$g} = $i;
		return $getgrnamC{$g};
	}
	 

	my $gid;
	if ($group =~ /^(\d+)$/)
	{
		$uid = int $1;
	}
	else
	{
		# Otherwise attempt to look up the group to get a GID.  Default
		# to GID 0 if the group can't be found.
		$gid = &getgrnamC($group);
	}

	return $gid;
}

# Returns false if the permissions of the given file match the given
# permissions, true otherwise.
sub compare_permissions
{
	my $file = shift || &bug('No file received');
	my $newperms = shift || &bug("No perms received");
	$newperms = octify($newperms);

	return if (! -e $file);

	# Mask off the file type
	my $st = lstat($file) || &away("unable to stat $file: $!");
	my $perms = $st->mode & 07777;
	if ($perms == $newperms) { return 0; }
	else { return 1; }
}

# Returns false if the ownership of the given file match the given UID
# and GID, true otherwise.
sub compare_ownership
{
	my $file = shift || &bug("No file received");
	my $uid = shift;  # Can be zero
	&bug("No uid received") if (! defined $uid);
	my $gid = shift;  # Can be zero
	&bug("No gid received") if (! defined $gid);

	return if (! -e $file);

	my $st = lstat($file) || &away("unable to stat $file: $!");
	if ($st->uid == $uid && $st->gid == $gid) { return 0; }
	else { return 1; }
}

sub remove_file
{
	my $file = shift || &bug("No file received");

	if (-d $file) { system("rm -rf $file"); }
	else { unlink $file || &away("unable to remove $file:  $!"); }
}
sub uoctify
{
	my $perms = shift || &bug("No perms received");
	return sprintf("%04o", $perms & 07777);
}
sub octify
{
	my $perms = shift || &bug("No perms received");
	$perms = '0' . $perms if ($perms !~ /^0/);
	return oct $perms;
}

sub lock_file
{
        my $file = shift || &bug("No lock_file file received");
	#&bug("lock file: $file", 1);

        my $lockpath = File::Spec->canonpath("$LOCKBASE/$file.LOCK");

        # Make sure the directory tree for this file exists in the
        # lock directory
        &makepath($lockpath, 0, "0777");

	# force through stale lock files older than 3 minutes
        if (-f $lockpath)
        {
                my $st = lstat($lockpath);
                if ( time - 180 > $st->mtime )
                {
                        &log("Found stale lock for $file, continuing...\n");
                        unlink($lockpath);
                }
        }

        # Make 3 minute worth of attempts (1s sleep after each attempt)
        for (my $count=179; $count>0; $count--)
        {
                unlink($lockpath) if ($force);
                my $r = sysopen(LOCK, $lockpath, O_WRONLY|O_CREAT|O_EXCL);
                if ($r)
                {
                        #&log("Lock acquired for $file\n", 4);
                        print LOCK $$, "\n";
                        close(LOCK);
                        &chmod('0777', $lockpath, 9);
                        return;
                }
                else
                {
                        &log("Attempt to acquire lock for $file failed ($lockpath), retrying for $count sec\n");
                        sleep 1;
                }
        }

        &log("Unable to acquire lock for $file after repeated attempts, continuing...\n");
}

sub unlock_currently_locked_file
{
	my $signal = shift;

	# Work around brokenness in XML::Parser
	return if ($signal && $signal =~ m,XML/Parser/Expat.pm,);

	if ($currently_locked_file)
	{
		unlock_file($currently_locked_file);
		$currently_locked_file = '';
	}

	exit if ($signal && $signal eq 'INT');
}

sub unlock_file
{
	my $file = shift || &bug("No file received");

	my $lockpath = File::Spec->canonpath("$LOCKBASE/$file.LOCK");

	if (-f $lockpath)
	{
		open(LOCK, '<', $lockpath) || &away("unable to open $lockpath:  $!");
		my $pid = <LOCK>;
		close(LOCK);
		chomp($pid);
		if ($pid == $$)
		{
			#&log("Unlocking $file\n", 9);
			unlink($lockpath) || &away("unable to remove $lockpath: $!");
		}
		else
		{
			# This shouldn't happen, if it does it's a bug
		        &log("Asked to unlock $file which is locked by another process\n");
        		eval {no warnings; print IPC "ERROR\n"; close(IPC); };
        		exit(1);
		}
	}
	else
	{
		# This shouldn't happen
		&log("Lock for $file lost\n");
	}
}

# Compares the last modification file of all entries in the directory
# for $file against a timestamp file in our scratch area to determine if
# any of the source files have been modified since this file was last
# checked.  Returns true if any of the source files are newer
# (indicating that a full generate run should be performed to determine
# if the file needs to be updated).
sub check_timestamp
{
	my $file = shift || &bug("No file received");

	my $stamppath = File::Spec->canonpath("$STAMPBASE/$file.STAMP");
	my $r = 0;

	# Check to see if a timestamp record exists for this file.  If not
	# then this is is the first timestamp check for this file.
	if (! -f $stamppath)
	{
		$r = 1;
	}
	else
	{
		my $st = lstat($stamppath) || &away("unable to stat $stamppath: $!\n");
		my $stamp = $st->mtime;

		opendir(S, "$SOURCEBASE/$file") || &away("unable to read directory $SOURCEBASE/$file: !$\n");
		foreach my $entry (readdir(S))
		{
			my $st1 = lstat("$SOURCEBASE/$file/$entry") || &away("unable to stat $SOURCEBASE/$file/$entry: $!\n");
			if ($st1->mtime > $stamp)
			{
				$r = 1;
			}
		}
		closedir(S);
	}

	return $r;
}

sub update_timestamp
{
        my $file = shift || &bug("No update_timestamp file received");

        my $stamppath = File::Spec->canonpath("$STAMPBASE/$file.STAMP");

        # Make sure the directory tree for this file exists in the
        # timestamp directory
        &makepath($stamppath, 0, "0777");

        # And "touch" the timestamp file
        open(TS, '>', $stamppath) || &away("unable to open $stamppath: $!\n");
        close(TS);
        CORE::chmod(0777, $stamppath);
}

# Loads external hooks  
sub loadhooks()
{
	our %HOOKS;
	my $dir = "$CONFIGBASE/hooks";
	return if (! -d $dir);

	# Find external hooks to load
	opendir(DIR, $dir);
	map { $SELF = "$dir/$_"; $NAME = $_; require "$dir/$_" if (-f "$dir/$_" && !/^\./ && !/\.disabled$/); $SELF = $NAME = ''; } sort { $a cmp $b } readdir(DIR);
	close(DIR);
}

sub initsystem()
{
        #
        # Load the defaults.xml file which sets defaults for parameters that the
        # user doesn't specify in his config.xml files.
        #
        &away("$CONFIGBASE/defaults.xml does not exist! Wrong CONFIG directory?\n") if (! -f "$CONFIGBASE/defaults.xml");
        our $defaults_xpath = XML::XPath->new(filename => "$CONFIGBASE/defaults.xml");

        # set global settings
        our $VARBASE = $defaults_xpath->getNodeText('/config/VARBASE');
        &away("VARBASE is not set in $CONFIGBASE/defaults.xml\n") if (!$VARBASE);
        our $ORIGBASE =  "$VARBASE/orig";
        our $LOCKBASE =  "$VARBASE/locks";
        our $STAMPBASE = "$VARBASE/timestamps";

        our $LOG = $defaults_xpath->getNodeText('/config/LOG');
        warn "LOG not configured in defaults, not logging.\n" if (!$LOG);
        our $LOGDAYS=$defaults_xpath->getNodeText('/config/LOGDAYS') || 30;
        $LOGDAYS = int($LOGDAYS);
        &loginit();

	#
        # Set Path
        #
        $ENV{'PATH'} = $defaults_xpath->getNodeText('/config/PATH') .':'. $ENV{'PATH'} if ( $defaults_xpath->exists('/config/PATH') );

        #
        # Etch is forbidden to run on few very important hosts
        #
        &forbiddenhosts();
}

# 'our' instead of 'my' declaration on these variables so that they can
# be shared with a Safe compartment.
sub findsystem
{
	our ($FULLARCH, $ARCH, $OS, $OSVERSION, $HOSTNAME, $LINUXDISTRO, $LINUXDISTROVERSION);

	($OS, $HOSTNAME, $OSVERSION, $FULLARCH) = split(/\s+/, lc(`uname -prsn`));
	($ARCH) = split('_', $FULLARCH); 	

	our $LINUXDISTRO = '';
	our $LINUXDISTROVERSION = '';
	if ($OS eq 'Linux')
	{	
        	if (-f '/etc/redhat-release')
        	{
                	open(RR, '<', '/etc/redhat-release') || &away("unable to open /etc/redhat-release: $!\n");
                	my $rr = <RR>;
                	close(RR);
			if ($rr =~ /Red Hat Linux release ([\d\.]+)/)
                	{
                        	$LINUXDISTRO = 'Red Hat';
                        	$LINUXDISTROVERSION = $1;
                	}
                	elsif ($rr =~ /Red Hat Linux Advanced Server release ([\d\.]+)/)
                	{
                        	$LINUXDISTRO = 'Red Hat';
                        	$LINUXDISTROVERSION = "EL $1 AS";
                	}
                	elsif ($rr =~ /Red Hat Enterprise Linux (AS|ES|WS) release ([\d\.]+)/)
                	{
                        	$LINUXDISTRO = 'Red Hat';
                        	$LINUXDISTROVERSION = "EL $2 $1";
                	}
                	elsif ($rr =~ /Fedora Core release ([\d\.]+)/)
                	{
                        	$LINUXDISTRO = 'Red Hat';
                        	$LINUXDISTROVERSION = "FC $1";
                	}
        	}
        	# The rest of these haven't been completed or tested
        	elsif (-f '/etc/SuSE-release')
        	{
                	$LINUXDISTRO = 'SuSE';
        	}
        	elsif (-f '/etc/mandrake-release')
        	{
                	$LINUXDISTRO = 'Mandrake';
        	}
        	elsif (-f '/etc/debian_version')
        	{
                	$LINUXDISTRO = 'Debian';
        	}
        	elsif (-f '/etc/slackware-release')
        	{
                	$LINUXDISTRO = 'Slackware';
        	}
	}

	#
	# Load the hosts file
	#
	&loadhosts();

        # current user info
	my @c = getpwuid($>);
	my @g = getgrgid($c[3]);
	our $SYSTEMOWNER = $c[0];
	our $SYSTEMUID = $c[2];
	our $SYSTEMGROUP = $g[0];
	our $SYSTEMGID = $g[2];

	# Load External hooks
	&loadhooks();
}
sub listsystem
{
	my $arg = shift || 'info'; 
	$arg = lc($arg);

	my $d = 0;
	$d = $debug if ($debug && !$runas || $arg eq 'info');
	$d+=2 if ( $arg eq 'info' );

	&findsystem();

	# Print Debug information
	if    ($arg eq 'arch') 	   { &display("$ARCH\n"); }
	elsif ($arg eq 'fullarch') { &display("$FULLARCH\n"); }
	elsif ($d > 1)	       	   { 
				     if ($ARCH eq $FULLARCH) { &display("ARCH: $ARCH\n"); }
				     else { &display("ARCH: $ARCH, FULLARCH: $FULLARCH\n"); } 
                                   }

	if    ($arg eq 'os')   	{ &display("$OS\n"); }
       	elsif ($d > 1)	       	{ &display("OS: $OS\n"); }

	if    ($arg eq 'osversion') { &display("$OSVERSION\n"); }
	elsif ($d > 1)	       	    { &display("OSVERSION: $OSVERSION\n"); }

	if    ($arg eq 'hostname')  { &display("$HOSTNAME\n"); }
       	elsif ($d > 1)		    { &display("HOSTNAME: $HOSTNAME\n"); }

	if    ($arg eq 'linuxdistro') { &display("$LINUXDISTRO\n"); }
	elsif ($LINUXDISTRO && $d > 1)    { &display("LINUXDISTRO: $LINUXDISTRO\n"); }

	if    ($arg eq 'linuxdistroversion') { &display("$LINUXDISTROVERSION\n"); }
	elsif ($LINUXDISTROVERSION && $d > 1)    { &display("LINUXDISTROVERSION: $LINUXDISTROVERSION\n"); }

	if    ($arg eq 'user/group') { &display("$SYSTEMOWNER/$SYSTEMGROUP\n"); }
	elsif ($d > 1)	 	     { &display("USER/GROUP: $SYSTEMOWNER/$SYSTEMGROUP\n"); }

	if    ($arg eq 'config') { &display("$CONFIGBASE\n"); }
	elsif ($arg eq 'source') { &display(join(", ", @SOURCES)); }
	elsif ($d)		 { &display("CONFIG: $CONFIGBASE\n"); }

	if    ($arg eq 'hardware')          { &display(join("\n", sort @HARDWARE)); }
        elsif (@HARDWARE && $arg eq 'info') { &display("HARDWARE: \n". join("\n", map { "\t$_" } sort @HARDWARE) ."\n"); }
        elsif (@HARDAWRE && $d > 1)             { &display("HARDWARE: " . join(', ', @HARDWARE) . "\n"); }
	
	if    ($arg eq 'location')           { &display(join("\n", sort @LOCATION)); }
        elsif (@LOCATION && $arg eq 'info')  { my $i=0; &display("LOCATION: ". join("\n", map { $i++; ($i>1?"\t ":'') ."$_"; } sort @LOCATION) ."\n"); }
        elsif (@LOCATION && $d > 1)             { &display("LOCATION: " . join(', ', @LOCATION) . "\n"); }

	if    ($arg eq 'cluster')           { &display(join("\n", sort @CLUSTERS)); }
        elsif (@CLUSTERS && $arg eq 'info') { my $i=0; &display("CLUSTER: ". join("\n", map { $i++; ($i>1?"\t ":'') ."$_"; } sort @CLUSTERS) ."\n"); }
        elsif (@CLUSTERS && $d > 1)             { &display("CLUSTER: " . join(', ', @CLUSTERS) . "\n"); }

	

	if    ($arg eq 'duties' || $arg eq 'duty') { &display(join("\n", sort @DUTIES) ."\n"); }
	elsif ($arg eq 'info')			   { my $i=0; &display("DUTIES: ". join("\n", map { $i++; ($i>1?"\t":'') ."$_"; } sort @DUTIES) ."\n"); }
	elsif ($d > 1) 				   { &display("DUTIES: ". join(", ", sort @DUTIES) ."\n"); }

	if ($d && @MANUALDUTIES) { &display("MANUAL DUT". ($#MANUALDUTIES?"IES: ":"Y: ") . join(", ", sort @MANUALDUTIES) ."\n"); }
	if ($d && @manualfilesOriginal) { &display("MANUAL PATH: ". join(", ", @manualfilesOriginal) ."\n"); }

	if ($d > 8)
	{
       		&display("HOOKS are: \n");
		&display($DIV);
		print Dumper(%HOOKS);
		&display($DIV);
	}
	&display($DIV) if ($d);
}

# Load hosts.xml
sub loadhosts()
{
	my $hosts_xpath;
	if (-f "$CONFIGBASE/hosts.xml")
	{
        	$hosts_xpath = XML::XPath->new(filename => "$CONFIGBASE/hosts.xml");
	}
	else
	{
        	&away("No $CONFIGBASE/hosts.xml file\n");
	}

	# Extract the list of duties for this host
	my @dutynodes = $hosts_xpath->findnodes("/hosts/host[\@name='$HOSTNAME']/duty");
	foreach my $duty (map { $_->string_value } @dutynodes)
	{
        	push(@DUTIES, $duty);
	}
	
	# Extract the list of hardware for this host
	our @HARDWARE = ();
	my @devicenodes = $hosts_xpath->findnodes("/hosts/host[\@name='$HOSTNAME']/hardware");
	foreach my $device (map { $_->string_value } @devicenodes)
	{
        	push(@HARDWARE, $device);
	}

	# Extract the list of clusters for this host
	our @CLUSTERS = ();
	my @clusternodes = $hosts_xpath->findnodes("/hosts/host[\@name='$HOSTNAME']/cluster");
        foreach my $cluster (map { $_->string_value } @clusternodes)
        {
                push(@CLUSTERS, $cluster);
        }	

	# Extract the list of clusters for this host
        our @LOCATION = ();
        my @locationnodes = $hosts_xpath->findnodes("/hosts/host[\@name='$HOSTNAME']/location");
        foreach my $location (map { $_->string_value } @locationnodes)
        {
                push(@LOCATION, $location);
        }
}

sub parsecommandline()
{
	# Find ourselves
	our $CONFIGBASE = dirname(dirname(abs_path($0))) ."/etc/etch";;
	our $SOURCEBASE; # current source
	our @SOURCES; # contains multiple sources

	our $etchpush=0;
	our $debug=1;
	our $dryrun;
	our $timestamp;
	our $generateall;
	our $force;
	our ($nolocalsetup, $boostrap, $info);
	our $runas;	# ovewrites $TMPBASE and to indicate if we are in runas mode (ie: child of another etch)
	our $nocolor;
	my ($test, $info);
	our @DUTIES;
	our @MANUALDUTIES;
	our @EXCLUDES;
	our @INCLUDES;
	our $ACK;	# ack remote parent
	our @origARGV=@ARGV;
	our @OPTIONS; # Generate @OPTIONS in case we need to change process uid
	my $r = GetOptions(
        	'h|?|help' => sub { &usage() },
        	'nolocalsetup' => \$nolocalsetup,
        	'bootstrap' => \$bootstrap,
		'rsync-exclude=s' => sub { @EXCLUDES = split(/,|\s+/, $_[1]); push(@OPTIONS, "--exlude='$_[1]'"); },
		'rsync-include=s' => sub { @INCLUDES = split(/,|\s+/, $_[1]); push(@OPTIONS, "--include='$_[1]'"); },
        	'd|debug|dd:i' => sub { $debug=$_[1] || 1; push(@OPTIONS, "--debug=$debug"); },
        	'f|force' => sub { $force=$_[1]; push(@OPTIONS, "--force"); },
        	'n|dry-run' => sub { $dryrun=1; push(@OPTIONS, "--dry-run"); },
        	't|timestamp' => sub { $timestamp=$_[1]; push(@OPTIONS, "--timestamp"); },
        	'g|generate-all' => sub { $generateall=$_[1]; push(@OPTIONS, "--generate-all"); },
		'list' => sub { $dryrun=9; push(@OPTIONS, '--list'); },
		'i|info:s' => sub { $info=$_[1] || 'info'; $debug=0; },
        	'runas=i' => sub { $runas=$_[1]; push(@OPTIONS, "--runas=$runas"); },
		'test' => \$test,
		'push=s' => \$etchpush,
		'ack=i' => \$ACK,
		'no-color|no_color|nocolor|ansi_colors_disabled' => \$nocolor,
		'duty=s' => sub { @MANUALDUTIES = grep {$_} split(/,|\s+/, $_[1]); push(@OPTIONS, "--duty='$_[1]'"); },
		'withduty|with-duty=s' => sub { @DUTIES = split(/,|\s+/, $_[1]); push(@OPTIONS, "--withduty='$_[1]'"); },
		'source=s' => sub { @SOURCES = grep {$_} split(',', $_[1]); push(@OPTIONS, "--source='$_[1]'"); },
		'config=s' => sub { $CONFIGBASE=$_[1]; push(@OPTIONS, "--config='$_[1]'"); },
		);

	# set default sources
	push(@SOURCES, "$CONFIGBASE/source") if (!@SOURCES);

	if ($info) { &listsystem($info); exit; }

	# if in test mode, just exit with 0
	exit(0) if ($test);	

        # manualfile is used for saving original user file argument: ie: <rsync manual>
	our @manualfiles;
	our $manualfile;

	map { $generateall = 1 if ($_ eq '/'); push(@manualfiles, $_) } @ARGV;
	@manualfiles = ('/') if ($generateall || ($dryrun == 9 && !@manualfiles));
	our @manualfilesOriginal = @manualfiles if (!$generateall);

	# Overwrite $TMPBASE use
        # Preheat $TMPBASE
	our $PS = $$;
	$PS = $runas if ($runas);	
	# File that is used to keep track of which files have been worked on and interaction between kids
	umask 0;
        our $IPC = new Cache::FileCache({ 'namespace' => 'etch_'.$PS, 'default_expires_in' => 1800, 'cache_root' => "${VARBASE}/tmp/" });
	$IPC->Clear() if (!$runas);

	# Display a usage message if GetOptions() reported an error or if the
	# user did not specify a valid action to perform.
	if ($debug != 11) # debug == 11 == hostinformation
	{
		usage() unless ($r);
		usage() unless (@manualfiles || $generateall);
	}

	# Acknowledge previous process that we are starting requested work
	$IPC->set('ipc_etchpush', "<ACK>$ACK</ACK>") if ($ACK);	


	###
	# Determine if we are in local or in etchpush mode
	###
	if (basename($ENV{'ETCH'}) =~ /^etchpush/)
	{
		my $host = $ARGV[0];
		return &etchpush($host);
	}
}

# Runs etch on remote host
sub etchpush
{
	my ($host) = @_;
	&away("Invalid hostname!") if (!$host);

	# Generate options for remote
	my $options = join(' ', @OPTIONS);

	# Validate remote host
	#my $ip = gethostbyname($host);
	#&away("Unable to lookup hostname: $host\n") if (!$ip);

	# Read etchpush config
	my $cfg;
	if (-f "$CONFIGBASE/etchpush.xml")
	{
		$cfg = XML::XPath->new(filename => "$CONFIGBASE/etchpush.xml");
	}
	else
	{
		&away("No $CONFIGBASE/etchpush.xml file\n");
	}	

	# Connect method
	my %connect;
	my $defaultconnect = $cfg->getNodeText("/config/connect");
	if ($generateall || $debug == 11)
	{
		@{$connect{$defaultconnect}} = ();
	}
	else
	{
		foreach my $f (@manualfiles)
		{
			my $found=0;

			# Look in etchpush.xml
			foreach my $i ( $cfg->findnodes("/config/file") )
			{
				my $name = $i->getAttribute('name');
				if ($f =~ /^$name/)
				{
					my $j = $cfg->getNodeText("/config/file[\@name='$name']/connect") || $defaultconnect;
					push(@{$connect{$j}}, $f);
					$found=1;
				}
			}

			# Look in $SOURCEBASE
			if (!$found)
			{
	                	my $i;
                		foreach my $dir (split(/\//, $f))
                		{
                	        	$i .= "$dir/";
					foreach my $source ( @SOURCES )
					{
                	        		next if (! -f "${source}${i}config.xml");
	                        		my $xpath = &readconfig("${source}${i}");
						if (my $j = $xpath->getNodeText("/config/connect"))
						{
							push(@{$connect{$j}}, $f);
							$found=1;
						}
					}
        	        	}
			}

			# If still not found, then use defaultconnect	
			push(@{$connect{$defaultconnect}}, $f) if (!$found);
		}
	}

        our $LOG = $cfg->getNodeText('/config/LOG');
        warn "LOG not configured in defaults, not logging.\n" if (!$LOG);
        our $LOGDAYS=$cfg->getNodeText('/config/LOGDAYS') || 30;
        $LOGDAYS = int($LOGDAYS);
        &loginit();

	# Sync local etch configuration		
	&runcmd("Syncing local setup environment", $cfg->getNodeText("/config/localsetup"), 1) if ($cfg->exists("/config/localsetup") && !$nolocalsetup);  
	
	# Test and Create environment if in generateall mode - no reason to run this if user already selected to bootstrap
	my $failedtest=0;
	if ($cfg->exists("/config/remotetest") && !$bootstrap)
	{
		my $command = $cfg->getNodeText("/config/remotetest");
		my $cmd = $defaultconnect;
		$cmd =~ s/::HOST::/$host/g;
		$cmd =~ s/::COMMAND::/$command/g;
		&display("COLOR:green:Checking remote host: $host\n");
		&logprepush();
		my $ret = &runcmd("", $cmd, 0, 1);
		if ($ret)
		{
			&display("remote test failed!\n");
			$failedtest=1;
			if ($bootstrap | ($failedtest && !$generateall))
			{
				&display("COLOR:red:Generate-all or bootstrap option is not used, not proceeding with bootstrap!\n");
				exit;
			}
		}
		&logprepop();
	}

	# Sync remote etch configuration
	if (($bootstrap | ($failedtest && $generateall)) && $cfg->exists("/config/remotesetup") )
	{
		my $c = $cfg->getNodeText("/config/remotesetup");
		$c =~ s/::HOST::/$host/g;
		&display("COLOR:green:Bootstrapping: $host\n");
		&logprepush();
		my $ret = &runcmd('', $c, 1);
		&logprepop();
	}

	# Start remote etch
	my $etch = $cfg->getNodeText("/config/etch") || &away("remote etch command<etch> not found in etchpush.xml");
	while (my ($c, $f) = each %connect)
	{
		my $pushstring = ($generateall?md5_hex('default'):md5_hex($c));
		my $command = "$etch $options --push=$pushstring";
	
		my $msg = "Running etch on $host";
		if ($debug == 11)
		{
			$msg .= ":[info]\n";
		}
		else
		{
			if (!$generateall)
			{ 
				my $files = join(' ', @{$f});
				$command .= " $files";
				$msg .= ":[$files]";
			}
			$msg .= " with options: $options\n";
		}

		my $run = $c;
		$run =~ s/::HOST::/$host/g;
                $run =~ s/::COMMAND::/$command/g;

		&display("COLOR:green:$msg");
		&log("\t$run\n", 8);
		my $pid = open(OUTPUT, "$run |")  or die "Couldn't fork: $! : $run\n";
		while(<OUTPUT>)
		{
			if (/<etchpush id='(\d+)' mode='(.*?)' ps='(\d+)' file='(.*?)'>(.*?)<\/etchpush>/)
			{
				my ($id, $mode, $ps, $file, $msg) = ($1, $2, $3, $4, $5);
				if ($mode eq 'connect' && $id && $ps && $file && $msg && !$generateall)
				{
					&log("Request for new connect method received.\n", 6);
					my $c2 = ($msg eq 'default'?$defaultconnect:$msg);
					my $pushstring = md5_hex($msg);
					my $command = "$etch $options --push=$pushstring --runas=$ps --ack=$id $file";
					my $run = eval "\"$c2\"";

					&log("\t$run\n", 8);
				
					system($run);
					last if ($? != 0);	
				}	
			}
			else
			{
				&log($_);
			}
		}
		close(OUTPUT);

		if ($? != 0)
                {
                	&display("COLOR:red:ETCH failed!\n");
			last;
                }
	}

	&quit($? >> 8);
}

# communicate to etchpush
sub ipc_etchpush($$$)
{
	my ($file, $msg, $mode) = @_;
	
	my $id = int rand(999999);
	print "<etchpush id='$id' mode='$mode' ps='$PS' file='$file'>$msg</etchpush>\n";

	# wait 30 seconds for reply, if not replied by then, exit
	sleep(3);
	my $listen = 'ack';
	for (my $i=0; $i<29; $i++)
	{
		if (my $out = $IPC->get('ipc_etchpush'))
		{
			if ($listen eq 'ack' && $out =~ /<ACK>(\d+)<\/ACK>/)
			{
				if ($id == $1)
				{
					&log("Received ACK from etchpush, will wait for FIN indefinately.\n", 8);
					$listen = 'fin';
				}
			}	
			elsif ($listen eq 'fin' && $out =~ /<FIN>(\d+)<\/FIN>/)
			{
				if ($id == $1)
				{
					&log("Received FIN from etchpush.\n", 8);
					return;
				}
			}
		}
		if ($listen eq 'ack')
		{
			&log("Waiting for ACK with id=$id from etchpush, sleeping 1s\n", 8);
		}
		sleep 1;
	}

	# Wait for FIN from the other process
	
	&away("Have not received ACK from etchpush after repeated attempts.\n");
}

# runs command with rotating progress bar
sub runcmd
{
	my $desc = shift;
	my $cmd = shift;
	my $track = shift || 0;	
	my $continue = shift || 0;

	if ($debug > 8) { &log("$desc.\n") if ($desc); &log("Command:\n $cmd\n"); }
	else		{ &display("$desc.") if ($desc); &log("Command:\n $cmd", 8); }

	sub progress($)
	{
        	my $i = shift;
        	if    ($$i eq '[|]') { $$i='[/]';  }
        	elsif ($$i eq '[/]') { $$i='[-]';  }
        	elsif ($$i eq '[-]') { $$i='[\\]'; }
        	else                 {  $$i='[|]'; }
	}

        my ($i, $j) = ('', '');
        my $pid = open(OUTPUT, "$cmd |")  or die "Couldn't fork: $! : $cmd\n";
        my $stat = '';
	my @lastlines;
        while(<OUTPUT>)
        {
		push(@lastlines, $_);	
		shift(@lastlines) if (!$#lastlines > 9); # keep last 10 linues to display as part of error if error is encountered

		if ($debug >= 9)
		{
			&log($_, $debug);
		}	
		else
		{
			&log($_, 'display');
			if (/(\d+ files to consider)|\((\d+.*?of \d+)\)/) { $j = "$1$2" if ($1 && $2); }
			if (/, to-check=(\d+\/\d+)/)			  { $stat = $1;  }
                	&display("\r". ($desc?"$desc: ":'') ."${j} ${i} ${stat}\t\t\t");
                	&progress(\$i);
		}
        }
        close(OUTPUT);
        $ret = $?;
        if ($ret && !$continue)
        {
		&display("COLOR:magenta:\n". join("\n", @lastlines)) if ($debug < 9);
                &display("COLOR:red:\nError detected, exiting!\n");
                exit($ret);
        }
	return $ret;
}

sub usage
{
        my $help =      "\t--generate-all|-g      Can be used instead of giving a specific path\n". 
			"\t                         to generate. This option or path is REQUIRED.\n".
			"\t--list                 Lists matched configuration files.  Similar to dry-run.\n".
			"\t--module=NAME1,NAME2   Only work on files tied to this module(s). Multiple\n".
			"\t                         values can be specified with comma delimiter.\n".
			"\t--withmodule=NAME1,NAME2 Additional modules can be assigned at run time. Multiple\n".
			"\t                          values are comma delimited.\n".
                        "\t--debug|-d|dd=#        Print lots of messages about what etch is doing\n".
                        "\t                         1 : Simple output information\n".
                        "\t                         5 : Show rsync information\n".
                        "\t                         7 : Show processing file information\n".
                        "\t                         9 : Show all debug information\n".
                        "\t--force|-f             Force file generation even if a lock is found\n".
                        "\t--dry-run|-n           Prints contents of generated files instead of\n".
                        "\t                         writing them out to disk.\n".
                        #"\t--timestamp|-t        Use the modification times of the source files\n".
                        #"\t                         in the repository to decide if each file needs\n".
                        #"\t                         to be generated, a la make.  This saves CPU\n".
                        #"\t                         cycles but might not update everything that\n".
                        #"\t                         needs updating.  A full run of etch (without\n".
                        #"\t                         this flag) should be performed occasionally.\n".
			"\t-i[=name]              Print information about host.\n". 
			"\t                         ie: '-i=duties' will output duties, to be used by outside\n".
			"\t--help|-h|?            Prints help.\n".
			"\t--nocolor              Disable color in output.\n".
			"\t--rsync-include        Include files matching rsync pattern. Include only works in <rsync>.\n".
                        "\t--rsync-exclude        Exclude files matching rsync pattern. Include only works in <rsync>.\n".
			"\t                         Multiple values are comma delimited.\n".
			"\t--source=DIRECTORY     Use this source directory, default is in etc/etch/source.\n".
			"\t                         Multiple values are comma delimited.\n".
			"\t--config=DIRECTORY     Use this config directory, default is in etc/etch\n".
			"\t                         Useful when you want to have multiple teams work\n".
			"\t                         on different parts of the system.\n";
	if (basename($ENV{'ETCH'}) =~ /^etchpush/)
	{
        $help =	        "Usage: etchpush HOSTNAME [options] </path/to/etch | -g | -i --list>\n".
			"Etchpush is a bootstrap wrapper for etch.\n".
			$help.
			"\t$DIV".
                        "\t--bootstrap'           (etchpush only) Build fresh system.  If remotetest fails\n".
			"\t                         this option is used automatically. \n".
			"\t                         --generate-all is required for boot strap.\n".
			"\t--nolocalsetup'        (etchpush only) Skip localsetup on etchpush host\n";
	}
	else
	{
		$help =		"Usage: etch [options] </path/to/etch | -g>\n".$help;
	}
	$help =		"SysEtch, configuration management done simple.\n". $DIV . $help;
	&display($help);
	exit;
}

# Etch will not run on hosts in <forbiddenhosts><host>
sub forbiddenhosts()
{
	foreach my $i ( $defaults_xpath->findnodes("/config/forbiddenhosts/host") )
        {
		my $fhost = $i->string_value;
		$fhost = qr/$fhost/;
		if ($HOSTNAME =~ /^$fhost$/)
		{
			&away("ERROR! $HOSTNAME is detected as forbidden host from defaults.xml\n");
		}
	}
}

# print output
sub display
{
        my $msg = shift;
	my $shift = shift;
	$shift = 1 if (!defined $shift);

	my $color = '';
	my $f = (caller($shift))[3];
	if ($f eq 'main::__ANON__' && $shift > 0)
	{
		$f = (caller(2))[3];
	}
	my $logme=1;
	my $modify=0;
	if ($f)
	{
		if    ($f =~ /main::(generate_|symlink)/)		{ $color = 'green'; $modify=1;	}	
		elsif ($f =~ /etchpush|runcmd/)		{ $color = 'green'; }
		elsif ($f =~ /runcmd/)			{ $color = 'green'; $logme=0; }
		elsif ($f =~ /main::process_runas/) 	{ $color = 'yellow'; 	}
		elsif ($f =~ /main::process_depend/) 	{ $color = 'yellow'; 	}
		elsif ($f =~ /main::findsystem/)	{ $color = 'yellow';    }
		elsif ($f =~ /main::process_rsync/ && $shift == 1) { $color = 'cyan';  }
		elsif ($f =~ /main::fobidden/)  	{ $color = 'magenta';   }
		elsif ($f =~ /main::away/)      	{ $color = 'magenta';   }
		elsif ($f =~ /main::bug/)		{ $color = 'magenta';   }
		elsif ($f =~ /main::usage/)		{ $logme=0; }
	}

	# color output based on content of message
	$color = 'red' if ($msg =~ /ERROR|failed|not proceeding/i);

	if ($msg =~ /^COLOR:(.*?):/)
	{
		$color = $1;
		$msg =~ s/^COLOR:$color://;
	}

	# Append to display if we are not in debug mode and display came from generate_
	if (!$debug && $modify)
	{
		chomp($msg);
		$msg = "Etching: $FILE - $msg ". ($dryrun?'(DRYRUN)':'') ."\n";
	}

	&log($msg, 'display') if ($logme);
	#print color($color) if ($color && !$nocolor);
	print join('', @LOGPRE) . (($color && !$nocolor)?colored($msg, $color):$msg);
	#print color('reset') if ($color && !$nocolor);	
}

# log all actions
sub log
{
	my $msg = shift;
	# using opt as debug filter
	my $opt = shift || 1;
	
	our $LOGMSG={'prev' => ''} if (!defined $LOGMSG);

	chomp($msg);

	# dont log duplicate messages
	return if ($msg eq $LOGMSG->{prev});
	$LOGMSG->{prev} = $msg;

	return if (!$LOGFILE);	
	if ($opt ne 'display')
	{
		if ($opt)
		{
			print join('', @LOGPRE) ."$msg\n" if ($debug >= $opt);
		} 
		else
		{
			print join('', @LOGPRE) ."$msg\n";
		}
	}

	open(FILE, ">>$LOGFILE");
        print FILE join('', @LOGPRE) ."$msg\n";
        close(FILE);	
}
sub loginit()
{
	return if (!$LOG);
	mkdir($LOG, 0755) if (! -d $LOG);

	our $PRE='    ';
	# set prefix for log print
	our @LOGPRE;

	my $now = time;
	my @t = localtime($now);
	our $LOGFILE = "$LOG/etch-". sprintf('%4d%02d%02d%02d%02d%02d', $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
	@t = localtime($now - $LOGDAYS * 86400);
	my $expire = sprintf('%4d%02d%02d000000', $t[5]+1900, $t[4]+1, $t[3]);

	my $dir;
	opendir($dir, $LOG);
	foreach my $file (<$dir>)
	{
		next if ($file !~ /etch-(.*)/);
		if ($expire > $1)
		{
			&log("Clearing expired log: $file");
			unlink("$LOG/$file");
		}
	}
	closedir($dir);
	&display($DIV);
}
# two functions that either add or delete \t, this helps in making the log output more human readable
sub logprepush()
{
	push(@LOGPRE, $PRE);	
}
sub logprepop()
{
	pop(@LOGPRE);
}

# Gracefully die
sub away 
{
        my $msg = shift || 'UNKNOWN ERROR';
        my $code = shift;
	$code = 2 if (! defined $code);

        &display("$msg\n");
        eval {  no warnings; print IPC "ERROR\n"; close(IPC); };

	&quit($code);
}

# Display bug
sub bug
{
	my $msg = "BUG: ". ($BUGMSG?"($BUGMSG)\n":"") ." ". shift;
	my $noexit = shift || 0;

	my @roadmap;
	# build roadmap that led to bug
	no warnings;
	for (my $x = 0; $i < 99; $i++)
	{
		my $l = (caller($i-1))[2];
		next if (!$l);
		my $f = (caller($i))[3] || 'main';
		next if ($f eq 'main::__ANON__');
		unshift(@roadmap, "${f}():${l}") ;
	}	

	chomp($msg);
	$msg .= "\nMAP: ". join(' -> ', @roadmap) ."\n";	
	&display($msg);

	eval {  no warnings; print IPC "ERROR\n"; close(IPC); };
	&unlock_currently_locked_file();
	&quit(255) if (!$noexit);
}
# init message that bug will display if bug is invoked
sub buginit
{
	our $BUGMSG = shift || '';
}


sub quit
{
	my $exit = shift || 0;
        # cleanup afterself
        &unlock_currently_locked_file();
	if (defined $IPC)
	{
		if ($ACK)
		{
			$IPC->set('ipc_etchpush', "<FIN>$ACK</FIN>");
		}
		elsif (!$runas)
		{
        		$IPC->Clear();
		}
	}
	&unlock_currently_locked_file();

	&display(localtime(time) .": Done\n");
	&display($DIV);

        # send exit code
        exit($exit);
}

sub readconfig($)
{
	my $file = shift;
        if (! -f "$file/config.xml" && ! -f "$file/conf.xml") { &bug("config.xml or conf.xml does not exist for $file\n"); }

        # Use XML::Twig to load and filter the config.xml, removing any
        # elements that don't apply to this host.
	my $cfile = "$file/config.xml";
	$cfile = "$file/conf.xml" if (-f "$file/conf.xml");
        my $twig = XML::Twig->new( twig_handlers => { _all_ => \&check_attributes } );
	&buginit("$cfile for $file is malformed");
        $twig->safe_parsefile($cfile) || &bug("$cfile for $file is malformed");
	&buginit();

        # Check the filtered file against the DTD
        my $filtered_xml = $twig->sprint;
	
	# Now read the filtered XML into an XML::XPath object
        my $xpath = XML::XPath->new( xml => $filtered_xml );
	return($xpath);
}

INIT 
{
	&buginit();
        $SIG{__DIE__} = sub { &bug($_[0]); };
        $SIG{INT} = sub { &away($_[0]); };
        $SIG{'__WARN__'} = sub { &display($_[0]); };
}

