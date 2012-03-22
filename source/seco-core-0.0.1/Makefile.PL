use 5.006000;
use ExtUtils::MakeMaker;

WriteMakefile(

    NAME         => 'Seco::Core',
    VERSION_FROM => 'lib/Seco/Core.pm',
    (

      $] >= 5.005
      ? (

         ABSTRACT => 'Seco core libaries',
         AUTHOR   => 'tingle2008@gmail.com',
        )

      : () ),

);
