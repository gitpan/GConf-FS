#!/usr/bin/perl -w

#####################################################################
#                                                                   #
# Copyright (c) 2006 by Laurent Simonneau                           #
#                                                                   #
# This library is free software; you can redistribute it and/or     #
# modify it under the terms of the GNU Library General Public       #
# License as published by the Free Software Foundation; either      #
# version 2 of the License, or (at your option) any later version.  #
#                                                                   #
# This library is distributed in the hope that it will be useful,   #
# but WITHOUT ANY WARRANTY; without even the implied warranty of    #
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU #
# Library General Public License for more details.                  #
#                                                                   #
# You should have received a copy of the GNU Library General Public #
# License along with this library; if not, write to the             #
# Free Software Foundation, Inc., 59 Temple Place - Suite 330,      #
# Boston, MA  02111-1307  USA.                                      #
#                                                                   #
#####################################################################

##############################################################

=head1 NAME

gconf-fs.pl - A FUSE implentation showing a gconf tree as a
directory and file tree.

=head1 SYNOPSIS

gconf-fs.pl <gconf_address_1> <gconf_address_2> ... <mount_point>

=head1 OPTIONS

=over

=item *
<gconf_address_*> : A list of gconf addresses (like xml:readwrite:/path/to/directory).
                    Use the default adresses (current user gconf tree) if no gconf
                    addresses are specified.

=item *
<mount_point>     : The mount point

=back

=cut

##############################################################

use strict;
use Fcntl ':mode';
use Fuse;
use POSIX qw(ENOENT EBADF EACCES EINVAL O_RDWR O_WRONLY);
use Carp;

use Data::Dumper;

use Getopt::Long;
use Gnome2::GConf;
use Pod::Usage;
use File::Basename;
use File::Path;
use IO::Scalar;

my %_OpenedFile = ();

# Check parameters
#
if(@ARGV < 1)
{
    pod2usage( -verbose => 1, -output => \*STDERR );
    exit(-1);
}
#
# End check parameters

# Check directories
#
my $mount_dir = pop @ARGV;
unless (-d $mount_dir)
{
    print STDERR $mount_dir. " is not a directory or does not exists.\n";
    exit 1;
}


# create GConf object
#

my $g_client;
if(@ARGV)
{
    my $g_engine = Gnome2::GConf::Engine->get_for_addresses(@ARGV);
    $g_client = Gnome2::GConf::Client->get_for_engine($g_engine);
}
else
{
    $g_client = Gnome2::GConf::Client->get_default();
}

$g_client->set_error_handling("handle-all");
$g_client->signal_connect(error => sub {
                            my ($client, $error) = @_;
                            warn "$error"; # is a Glib::Error
                        });


# Run FUSE
#
Fuse::main(
           # debug      => 1,
           mountpoint => "/tmp/fuse",

           fsync      => \&gconf_fsync,    # done

           getattr    => \&gconf_getattr,  # done

           getdir     => \&gconf_getdir,   # done
           mkdir      => \&gconf_mkdir,    # done
           rmdir      => \&gconf_rmdir,    # done

           rename     => \&gconf_rename,,  # done
           unlink     => \&gconf_unlink,   # done

           mknod      => \&gconf_mknod,    # done
           open       => \&gconf_open,     # done
           read       => \&gconf_read,     # done
           write      => \&gconf_write,    # done
           truncate   => \&gconf_truncate, # done
           release    => \&gconf_release,  # done
           flush      => \&gconf_flush,    # done

           # statfs     => \&gconf_statfs,   # not implemented
           # readlink   => \&gconf_readlink, # Not needed, symlinks does not exists in gconf
           # symlink    => \&gconf_symlink,  # Not needed, symlinks does not exists in gconf
           # link       => \&gconf_link,     # Not needed, hard links does not exists in gconf
           # chmod      => \&gconf_chmod,    # Not needed, rights can't be stored in gconf
           # chown      => \&gconf_chown,    # Not needed, owner can't be set in gconf
           # utime      => \&gconf_utime,    # Not needed, owner can't set dir ok key modification time gconf
          )
    or die $!;


#-------------------------------------------------------------
#
# gconf_fsync (path, mode)
#
# Called to synchronise the file's contents.
#
# For GConf fs just call g_client->suggest_sync().
#
# Arguments: Pathname, numeric flags.
#
# Returns an errno or 0 on success.
#
#-------------------------------------------------------------
sub gconf_fsync
{
    my ($file, $mode) = @_;
    $g_client->suggest_sync();
    return 0;
}


#-------------------------------------------------------------
#
# gconf_getattr (file)
#
# Arguments: filename.
#
# Returns a list, very similar to the 'stat' function
# (see perlfunc).
#
#-------------------------------------------------------------

sub gconf_getattr
{
    my ($file) = @_;

    return - EBADF() unless Gnome2::GConf->valid_key($file);

    my $mode   = S_IRUSR;
    my $length = 0;

    # Check if it's a directory
    #
    if($file eq '/' or $g_client->dir_exists($file))
    {
        $mode |= S_IFDIR | S_IXUSR | S_IWUSR;
    }

    # Check if it's a file, and populate mode and length
    #
    else
    {
        my ($key, $type) = _parse_filename($file);
        if(! defined $key or
           ! defined $type)
        {
            return - ENOENT();
        }

        my $val = _get_value($file);
        return $val if ref($val) ne 'Gnome2::GConf::Value' && $val < 0;

        $mode |= S_IFREG;
        $length = length($val->{value});

        # Lists, pairs and schama are read only
        #
        if($file !~ /(\.(list)|(pair)|(schema))$/ &&
           $g_client->key_is_writable($key))
        {
            $mode |= S_IWUSR;
        }
    }


    return (0, 0, $mode, 1, $<, $(, 0, $length, 0, 0, 0, 0, 0);
}

#-------------------------------------------------------------
#
# gconf_getdir (dir)
#
# This is used to obtain directory listings. Its opendir(), readdir(), filldir() and closedir() all in one call.
#
# Arguments: Containing directory name.
#
# Returns a list: 0 or more text strings (the filenames), followed by a numeric errno (usually 0).
#
#-------------------------------------------------------------

sub gconf_getdir
{
    my ($dir) = @_;

    return - EBADF() unless Gnome2::GConf->valid_key($dir);

    my @dirs = $g_client->all_dirs($dir);
    my @keys = $g_client->all_entries($dir);

    # Remove not set keys
    #
    @keys = grep { defined $_->{value}->{type} && $_->{key} !~ /_fake_key$/} @keys;

    @dirs = map { basename($_); } @dirs;
    @keys = map
              {
                  my $name = basename($_->{key}) . '.' . $_->{value}->{type};
                  $name .= ".list"
                      if ref($_->{value}->{value}) eq 'ARRAY';
                  $name;
              }
               @keys;

    return ('.', @dirs, @keys, 0);
}


#-------------------------------------------------------------
#
# gconf_mkdir (dir, $modes)
#
# Called to create a directory.
#
# Arguments: New directory pathname, numeric modes.
#
# Returns an errno.
#
#-------------------------------------------------------------

sub gconf_mkdir
{
    my ($dir, $modes) = @_;

    return - EBADF()  unless Gnome2::GConf->valid_key($dir);

    return - EACCES() unless $g_client->key_is_writable($dir);

    $g_client->set_string($dir . '/_fake_key', "");

    return 0;
}



#-------------------------------------------------------------
#
# gconf_rmdir (dir)
#
# Called to remove a directory.
#
# Arguments: Pathname
#
# Returns an errno.
#
#-------------------------------------------------------------

sub gconf_rmdir
{
    my ($dir) = @_;

    return - EBADF() unless Gnome2::GConf->valid_key($dir);

    return - EACCES() unless $g_client->key_is_writable($dir);

    $g_client->recursive_unset($dir);

    return 0;
}


#-------------------------------------------------------------
#
# gconf_rename (file)
#
# Called to rename a file, and/or move a file from one 
# directory to another.
#
# Arguments: old filename, new filename. 
#
# Returns an errno.
#
#-------------------------------------------------------------

sub gconf_rename
{
    my ($old, $new) = @_;

    return - EBADF() unless Gnome2::GConf->valid_key($old);
    return - EBADF() unless Gnome2::GConf->valid_key($new);

    my ($old_key, $old_type) = _parse_filename($old);
    if(! defined $old_key or
       ! defined $old_type)
    {
        return - ENOENT();
    }

    my ($new_key, $new_type) = _parse_filename($new);
    if(! defined $new_key or
       ! defined $new_type)
    {
        return - ENOENT();
    }
    # Check write access on both source and destination
    #
    return - EACCES() unless $g_client->key_is_writable($old_key);
    return - EACCES() unless $g_client->key_is_writable($new_key);

    my $val = $g_client->get($old_key);
    $g_client->set($new_key, $val);
    $g_client->unset($old_key);

    return 0;
}

#-------------------------------------------------------------
#
# gconf_unlink (file)
#
# Called to remove a file.
#
# Arguments: Pathname
#
# Returns an errno.
#
#-------------------------------------------------------------

sub gconf_unlink
{
    my ($file) = @_;

    return - EBADF() unless Gnome2::GConf->valid_key($file);

    my ($key, $type) = _parse_filename($file);
    if(! defined $key or
       ! defined $type)
    {
        return - ENOENT();
    }

    return - EACCES() unless $g_client->key_is_writable($key);

    $g_client->unset($key);

    return 0;
}


#-------------------------------------------------------------
#
# gconf_mknod (file, mode)
#
# This function is called for all non-directory, non-symlink nodes, not just devices.
#
# Arguments: Pathname, numeric flags (which is an OR-ing of stuff like O_RDONLY and O_SYNC, constants you can import from POSIX).
#
# Returns an errno.
#
#-------------------------------------------------------------

sub gconf_mknod
{
    my ($file, $mode) = @_;

    return - EBADF() unless Gnome2::GConf->valid_key($file);

    my ($key, $type) = _parse_filename($file);
    if(! defined $key or
       ! defined $type)
    {
        return - ENOENT();
    }

    return - EACCES() unless $g_client->key_is_writable($key);

    my %defval = (int => 0, string => '', float => 0, bool => 0);

    my $value = { type => $type, value => $defval{$type} };
    $g_client->set($key, $value);

    return 0;
}

#-------------------------------------------------------------
#
# gconf_open (file, mode)
#
# No creation, or trunctation flags (O_CREAT, O_EXCL, O_TRUNC) will be passed to open().
# Your open() method needs only check if the operation is permitted for the given flags,
# and return 0 for success.
#
# Arguments: Pathname, numeric flags (which is an OR-ing of stuff like O_RDONLY and O_SYNC, constants you can import from POSIX).
#
# Returns an errno.
#
#-------------------------------------------------------------

sub gconf_open
{
    my ($file, $mode) = @_;

    return - EBADF() unless Gnome2::GConf->valid_key($file);

    my ($key, $type) = _parse_filename($file);
    if(! defined $key or
       ! defined $type)
    {
        return - ENOENT();
    }

    my $val = _get_value($file);
    return $val if ref($val) ne 'Gnome2::GConf::Value' && $val < 0;

    # Disable write access on lists, pairs and schema.
    # and check write access on key
    #
    if( defined $mode &&
        ( $mode & O_RDWR  || $mode & O_WRONLY) &&
        ( 
          $file =~ /\.((list)|(pair)|(schema))$/ ||
          ! $g_client->key_is_writable($key)
        )
      )
    {
        return - EACCES;
    }

    # Cache an IO::String object for this key.
    #
    if(! exists $_OpenedFile{$file})
    {
        my $value = $val->{value};

        $_OpenedFile{$file}->{fh}    = new IO::Scalar(\$value);
        $_OpenedFile{$file}->{nbref} = 1;
        $_OpenedFile{$file}->{flush} = 0;
    }
    else
    {
        $_OpenedFile{$file}->{nbref} ++;
    }

    return 0;
}

#-------------------------------------------------------------
#
# gconf_read (file, size, offset)
#
# Called in an attempt to fetch a portion of the file.
#
# Arguments: Pathname, numeric requestedsize, numeric offset.
#
# Returns a numeric errno, or a string scalar with up to $requestedsize
# bytes of data.
#
#-------------------------------------------------------------

sub gconf_read
{
    my ($file, $size, $offset) = @_;

    return - EBADF() unless Gnome2::GConf->valid_key($file);

    if(!exists $_OpenedFile{$file})
    {
        return - EBADF();
    }

    my $buf;
    my $retval = $_OpenedFile{$file}->{fh}->seek($offset, 0);
    return - int($!) unless $retval;

    $retval = $_OpenedFile{$file}->{fh}->read($buf, $size, 0);
    return - int($!) unless defined $retval;

    return $buf;
}

#-------------------------------------------------------------
#
# gconf_write (file, buf, offset)
#
# Called in an attempt to write (or overwrite) a portion of the file.
# Be prepared because $buffer could contain random binary data with NULLs
# and all sorts of other wonderful stuff.
#
# Arguments: Pathname, scalar buffer, numeric offset. 
#            You can use length($buffer) to find the buffersize.
#
# Returns an errno.
#
#-------------------------------------------------------------

sub gconf_write
{
    my ($file, $buf, $offset) = @_;

    return - EBADF() unless Gnome2::GConf->valid_key($file);

    if(!exists $_OpenedFile{$file})
    {
        return - EBADF();
    }

    my $retval = $_OpenedFile{$file}->{fh}->seek($offset, 0);
    return - int($!) unless $retval;

    $retval = $_OpenedFile{$file}->{fh}->write($buf, length($buf), 0);
    return - int($!) unless defined $retval;

    $_OpenedFile{$file}->{flush} = 1;

    return $retval;
}

#-------------------------------------------------------------
#
# gconf_truncate (file, offset)
#
# Called to truncate a file, at the given offset.
#
# Arguments: Pathname, numeric offset.
#
# Returns an errno.
#
#-------------------------------------------------------------

sub gconf_truncate
{
    my ($file, $offset) = @_;

    return - EBADF() unless Gnome2::GConf->valid_key($file);

    my $retval = gconf_open($file, O_RDWR);
    return $retval if $retval;

    if(!exists $_OpenedFile{$file})
    {
        return - EBADF();
    }

    my $sref = $_OpenedFile{$file}->{fh}->sref;
    substr($$sref, $offset) = "";

    $_OpenedFile{$file}->{flush} = 1;

    $retval = gconf_release($file);

    return $retval;
}

#-------------------------------------------------------------
#
# gconf_release (file)
#
# Called to indicate that there are no more references to the file.
# Called once for every file with the same pathname and flags as were passed to open.
#
# Arguments: Pathname, numeric flags passed to open.
#
# Returns an errno or 0 on success.
#
#-------------------------------------------------------------

sub gconf_release
{
    my ($file) = @_;

    return - EBADF() unless Gnome2::GConf->valid_key($file);

    if(!exists $_OpenedFile{$file})
    {
        return - EBADF();
    }

    if($_OpenedFile{$file}->{flush})
    {
        gconf_flush($file);
    }

    $_OpenedFile{$file}->{nbref} = $_OpenedFile{$file}->{nbref} - 1;

    # Close the file if there is no more
    # references on it.
    #
    if($_OpenedFile{$file}->{nbref} == 0)
    {
        $_OpenedFile{$file}->{fh}->close();
        delete $_OpenedFile{$file};
    }

    return 0;
}


#-------------------------------------------------------------
#
# gconf_flush (file)
#
# Called to synchronise any cached data.
# This is called before the file is closed.
# It may be called multiple times before a file is closed.
#
# Arguments: Pathname
#
# Returns an errno or 0 on success.
#
#-------------------------------------------------------------

sub gconf_flush
{
    my ($file) = @_;

    return - EBADF() unless Gnome2::GConf->valid_key($file);

    if(!exists $_OpenedFile{$file})
    {
        return - EBADF();
    }

    return 0 if ($_OpenedFile{$file}->{flush} == 0);

    my ($key, $type) = _parse_filename($file);
    if(! defined $key or
       ! defined $type)
    {
        return - ENOENT();
    }

    return - EACCES() unless $g_client->key_is_writable($key);

    my $data = $_OpenedFile{$file}->{fh}->sref;

    if($type =~ /^int|float|bool$/)
    {
        chomp($$data);
        $$data = 0 if $$data eq '';
    }

    my $value = { type  => $type,
                  value => $$data,
                };

    $g_client->set($key, $value);

    $_OpenedFile{$file}->{flush} = 0;

    return 0;
}

#-------------------------------------------------------------
#
# _get_value (file)
#
# Return a hash ref describing value of the given key.
# The hash look like :
# {
#   type       : string|int|float|bool|pair|schema
#   value      : a printable representation of the value
#   list_value : Array ref containig values of keys with list type
#   car, cdr   : 'pair' values.
# }
#
#-------------------------------------------------------------

sub _get_value
{
    my ($file) = @_;

    my ($key, $type) = _parse_filename($file);

    if(! defined $key or
       ! defined $type)
    {
        return - ENOENT();
    }

    my $val = $g_client->get($key);
    if(! defined $val)
    {
        return - ENOENT();
    }

    # For special types (pair, list and schema)
    # Convert value into a printable string.
    #
    # These "files" are read only.
    #
    if($val->{type} eq 'pair')
    {
        $val->{value} =
            "car:$val->{car}->{type}:$val->{car}->{value}\n" .
            "cdr:$val->{cdr}->{type}:$val->{cdr}->{value}";
    }
    elsif($val->{type} eq 'schema')
    {
        $val->{schema_value} = $val->{value};
        $val->{value} = Dumper($val->{schema_value});
    }
    elsif(ref($val->{value}) eq 'ARRAY')
    {
        $val->{list_value} = $val->{value};
        $val->{value} = '[' . join(',', @{$val->{value}}) . ']';
    }


    return $val;
}


#-------------------------------------------------------------
#
# _parse_filename (file)
#
# Parse filenames.
#
# Returns a array ref like [ 'key name', 'type' ]
#
#-------------------------------------------------------------

sub _parse_filename
{
    my ($file) = @_;

    return ($file =~ /^(.*?)\.([^\.]*)(\.list)?$/);
}

#-------------------------------------------------------------
#
# _check_data_value (type, data)
#
# Check if the given data match the given type.
#
# Returns a correct data or croak on error.
#
#-------------------------------------------------------------

sub _check_data_value
{
    my ($type, $data) = @_;

    if($type eq 'int' or $type eq 'float')
    {
        croak "Not a numerical value" if $data !~ /^[-.]?[0-9]/;

        chomp($data);
    }
    elsif($type eq 'bool')
    {
        chomp($data);
        croak "Not a numerical value" if $data ne '1' and $data ne '0';
    }
    else
    {
        chomp($data);
    }

    return $data;
}

1;
