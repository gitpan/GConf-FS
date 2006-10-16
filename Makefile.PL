use ExtUtils::MakeMaker;

sub MY::postamble {
    return "

install:: my_\$(INSTALLDIRS)_install

my_site_install::
\tmkdir -p \$(DESTDIR)/\$(SITEPREFIX)/share/gconf-fs; \\
\tcp share/gconf-fs/* \$(DESTDIR)/\$(SITEPREFIX)/share/gconf-fs

my_vendor_install::
\tmkdir -p \$(DESTDIR)/\$(VENDORPREFIX)/share/gconf-fs; \\
\tcp share/gconf-fs/* \$(DESTDIR)/\$(VENDORPREFIX)/share/gconf-fs

my_perl_install::
\tmkdir -p \$(DESTDIR)/\$(PERLPREFIX)/share/gconf-fs; \\
\tcp share/gconf-fs/* \$(DESTDIR)/\$(PERLPREFIX)/share/gconf-fs

";
}

WriteMakefile(
        'NAME'             => 'GConf-FS',
        'VERSION'          => '0.02',
        'PREREQ_PM'        => { Fuse           => 0.07, 
                                Gnome2::GConf  => 1.043,
                                IO::String     => 1.08,
				XML::LibXML    => 1.58,
                              },

        'ABSTRACT'        => 'This script allows you to view a gconf tree as a file system',
        'AUTHOR'          => 'Laurent Simonneau <l.simonneau@free.fr>',

        'EXE_FILES'       => [ 'scripts/gconf-fs.pl' ],
);

