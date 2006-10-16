#!/usr/bin/perl -w

########################################################################
#                                                                      #
# Copyright (c) 2006 by Laurent Simonneau                              #
#                                                                      #
# This program is free software; you can redistribute it and/or modify #
# it under the terms of the GNU General Public License as published by #
# the Free Software Foundation; either version 2 of the License, or    #
# (at your option) any later version.                                  #
#                                                                      #
# This program is distributed in the hope that it will be useful,      #
# but WITHOUT ANY WARRANTY; without even the implied warranty of       #
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the        #
# GNU General Public License for more details.                         #
#                                                                      #
# You should have received a copy of the GNU General Public License    #
# along with this program; if not, write to the Free Software          #
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA        #
# 02110-1301  USA                                                      #
#                                                                      #
########################################################################

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
use Encode;

use XML::LibXML;

use Getopt::Long;
use Gnome2::GConf;
use Pod::Usage;
use File::Basename;
use File::Path;
use File::Spec;
use IO::String;

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


# Create LibXML parser
#
my $xml_parser = new XML::LibXML();

# Process RNG file path
# Not really clean but I don't want a config file.
#
my $cur_path  = File::Spec->rel2abs($0);
my $cur_dir   = dirname($cur_path);
my $rng_file = $cur_dir . '/../share/gconf-fs/gconf-fs.rng';

# Create Relax NG validator
#
my $rng_doc = eval { $xml_parser->parse_file($rng_file) };
if($@)
{
    die "Can't parse XML file pouette : $rng_file" . XML::LibXML->get_last_error();
}

my $rng_validator = new XML::LibXML::RelaxNG(DOM => $rng_doc)
    or die "Can't parse RelaxNG file pouette : $!";


# Run FUSE
#
Fuse::main(
           # debug      => 1,
           mountpoint => $mount_dir,

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
          );


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
        my $val = get_value($file);
        return $val if ref($val) ne 'Gnome2::GConf::Value' && $val < 0;

        $mode |= S_IFREG;
        $length = do { use bytes; length($val->{value}) };

        # Lists, pairs and schama are read only
        #
        if($g_client->key_is_writable($file))
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
    @keys = map { basename($_->{key}) } @keys;

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

    # Check write access on both source and destination
    #
    return - EACCES() unless $g_client->key_is_writable($old);
    return - EACCES() unless $g_client->key_is_writable($new);

    my $val = $g_client->get($old);
    $g_client->set($new, $val);
    $g_client->unset($old);

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

    return - EBADF()  unless Gnome2::GConf->valid_key($file);
    return - EACCES() unless $g_client->key_is_writable($file);

    $g_client->unset($file);

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

    return - EBADF()  unless Gnome2::GConf->valid_key($file);
    return - EACCES() unless $g_client->key_is_writable($file);

    my $value = { type => 'string', value => '' };
    $g_client->set($file, $value);

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

    my $val = get_value($file);
    return $val if ref($val) ne 'Gnome2::GConf::Value' && $val < 0;

    # Check write access on key
    #
    if( ! $g_client->key_is_writable($file) )
    {
        return - EACCES;
    }

    # Cache an IO::String object for this key.
    #
    if(! exists $_OpenedFile{$file})
    {
        my $value = $val->{value};

        $_OpenedFile{$file}->{fh}    = new IO::String($value);
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

    my $buf = "";
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

    $_OpenedFile{$file}->{fh}->truncate($offset);

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

    # Check file name validity and access right.
    #
    return - EBADF() unless Gnome2::GConf->valid_key($file);

    if(!exists $_OpenedFile{$file})
    {
        return - EBADF();
    }

    return 0 if ($_OpenedFile{$file}->{flush} == 0);
    return - EACCES() unless $g_client->key_is_writable($file);

    # Does nothing if the file is empty (caused by a truncate).
    #
    my $data = $_OpenedFile{$file}->{fh}->sref;
    if($$data eq '')
    {
        $_OpenedFile{$file}->{flush} = 0;
        return 0;
    }

    # Parse XML String
    #
    my $doc = eval { $xml_parser->parse_string($$data); };
    if($@)
    {
        warn "Error while parsing content of key $file : " . XML::LibXML->get_last_error();

        $_OpenedFile{$file}->{flush} = 0;
        return - EINVAL();
    }

    # Validate Document with RelaxNG
    #
    eval { $rng_validator->validate($doc); };
    if($@ ne "")
    {
        warn "Error while validation XML document : $@";

        $_OpenedFile{$file}->{flush} = 0;
        return - EINVAL();
    }

    # Convert XML document to a Gnome2::GConf::Value object
    # No error check, the XML is valid (validated with RNG)
    #
    my $root = $doc->documentElement;
    my $value = xml_to_value($root);

    # Store it into GConf
    #
    if($value->{type} ne 'schema')
    {
        $g_client->set($file, $value);
    }
    else
    {
        $g_client->set_schema($file, $value->{value});
    }

    $_OpenedFile{$file}->{flush} = 0;

    return 0;
}

#-------------------------------------------------------------
#
# get_value (file)
#
# Return a hash ref describing value of the given key.
# The hash look like :
# {
#   type       : string|int|float|bool|pair|schema
#   value      : a printable representation of the value
#   car, cdr   : 'pair' values.
#   schema     : schema description
# }
#
#-------------------------------------------------------------

sub get_value
{
    my ($file) = @_;

    my $val = $g_client->get($file);
    if(! defined $val)
    {
        return - ENOENT();
    }

    # Convert value into an XML string
    #
    my $xml_element = value_to_xml($val);
    $val->{value} = $xml_element->toString(1);

    return $val;
}


#-------------------------------------------------------------
#
# value_to_xml (val)
#
# Convert Gnome2::GConf::Value to XML description.
#
#-------------------------------------------------------------

sub value_to_xml
{
    my ($val) = @_;

    if($val->{type} eq 'pair')
    {
        return pair_to_xml($val);
    }
    elsif($val->{type} eq 'schema')
    {
        return schema_to_xml($val);
    }
    elsif(ref($val->{value}) eq 'ARRAY')
    {
        return list_to_xml($val);
    }
    else
    {
        my $element = new XML::LibXML::Element($val->{type});
        $element->appendText($val->{value});
        return $element;
    }

}

#-------------------------------------------------------------
#
# pair_to_xml (val)
#
# Convert a pair to a XML description.
#
#-------------------------------------------------------------

sub pair_to_xml
{
    my ($val) = @_;
    my $element = new XML::LibXML::Element('pair');

    foreach my $name qw(car cdr)
    {
        my $node = new XML::LibXML::Element($name);
        $node->appendText($val->{$name}->{value});
        $node->setAttribute('type', $val->{$name}->{type});

        $element->appendChild($node);
    }

    return $element;
}

#-------------------------------------------------------------
#
# list_to_xml (val)
#
# Convert a list to a XML description.
#
#-------------------------------------------------------------

sub list_to_xml
{
    my ($val) = @_;

    my $element = new XML::LibXML::Element('list');
    $element->setAttribute('type', $val->{type});

    foreach my $val (@{$val->{value}})
    {
        $element->appendTextChild('value', $val);
    }

    return $element;
}


#-------------------------------------------------------------
#
# schema_to_xml (val)
#
# Convert a schema to a XML description.
#
#-------------------------------------------------------------

sub schema_to_xml
{
    my ($val) = @_;
    my $element = new XML::LibXML::Element('schema');

    foreach my $key qw(owner short_desc locale type long_desc)
    {
        my $val = $val->{value}->{$key};
        $val = '' unless defined $val;

        $element->appendTextChild($key, $val);
    }

    my $node = new XML::LibXML::Element('default_value');
    if(defined $val->{value}->{default_value})
    {
        my $def_val = value_to_xml($val->{value}->{default_value});
        $node->appendChild($def_val);
    }
    $element->appendChild($node);

    return $element;
}


#-------------------------------------------------------------
#
# xml_to_value (element)
#
# Convert a XML description to a Gnome2::GConf::Value
#
#-------------------------------------------------------------

sub xml_to_value
{
    my ($element) = @_;

    my $type = $element->nodeName;

    if($type eq 'pair')
    {
        return pair_xml_to_value($element);
    }
    elsif($type eq 'schema')
    {
        return schema_xml_to_value($element);
    }
    elsif($type eq 'list')
    {
        return list_xml_to_value($element);
    }
    else
    {
        my $value = { type => $type };
        $value->{value} = base_type_xml_to_value($element);
        return $value;
    }

}


#-------------------------------------------------------------
#
# pair_xml_to_value (element)
#
# Convert a pair XML description to a Gnome2::GConf::Value.
#
#-------------------------------------------------------------

sub pair_xml_to_value
{
    my ($element) = @_;

    my $value = { type => 'pair' };

    my $car = $element->getElementsByTagName('car')->item(0);
    my $cdr = $element->getElementsByTagName('cdr')->item(0);

    $value->{car}->{type}  = $car->getAttribute('type');
    $value->{cdr}->{type}  = $cdr->getAttribute('type');
    $value->{car}->{value} = base_type_xml_to_value($car);
    $value->{cdr}->{value} = base_type_xml_to_value($cdr);

    return $value;
}

#-------------------------------------------------------------
#
# list_xml_to_value (element)
#
# Convert a list XML description to a Gnome2::GConf::Value.
#
#-------------------------------------------------------------

sub list_xml_to_value
{
    my ($element) = @_;

    my $value = {
                 type  => $element->getAttribute('type'),
                 value => []
                };

    my @data_list = $element->getElementsByTagName('value');

    foreach my $val (@data_list)
    {
        push @{$value->{value}}, base_type_xml_to_value($val);
    }

    return $value;
}


#-------------------------------------------------------------
#
# schema_xml_to_value (val)
#
# Convert a schema XML description to a Gnome2::GConf::Value
#
#-------------------------------------------------------------

sub schema_xml_to_value
{
    my ($element) = @_;

    my $value = { type => 'schema' };

    foreach my $key qw(owner short_desc locale type long_desc)
    {
        my $node = $element->getElementsByTagName($key)->item(0);
        next unless defined $node;

        $value->{value}->{$key} = get_node_value($node);
    }

    my $node = $element->getElementsByTagName('default_value')->item(0);
    $node = $node->firstChild;
    while(defined $node && $node->nodeType == 3)
    {
        $node = $node->nextSibling;
    }

    if(defined $node)
    {
        $value->{value}->{default_value} = xml_to_value($node);
    }

    return $value;
}

#-------------------------------------------------------------
#
# base_type_xml_to_value (val)
#
# Convert a base type value to a XML description.
#
#-------------------------------------------------------------

sub base_type_xml_to_value
{
    my ($element) = @_;

    my $data = get_node_value($element);

    chomp($data);

    $data =~ s/^ *//;
    $data =~ s/ *$//;

    return $data;
}

#-------------------------------------------------------------
#
# get_node_value (node)
#
# Return the text content of an XML node.
#
#------------------------------------------------------------

sub get_node_value
{
    my ($node) = @_;

    if(defined $node->firstChild)
    {
        return decode('utf-8', $node->firstChild->textContent);
    }

    return "";
}

1;
