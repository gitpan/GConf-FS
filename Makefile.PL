use ExtUtils::MakeMaker;

WriteMakefile(
        'NAME'             => 'GConf-FS',
        'VERSION'          => '0.01',
        'PREREQ_PM'        => { Fuse          => 0.01, 
                                Gnome2::GConf => 1.043,
                              },

        'ABSTRACT'        => 'This script allows you to view a gconf tree as a file system',
        'AUTHOR'          => 'Laurent Simonneau <l.simonneau@free.fr>',

        'EXE_FILES'       => [ 'scripts/gconf-fs.pl' ],
);

