#!/bin/sh

# This script is temporary until ghc-mod is fixed to reconfigure on change

# cabal clean && cabal configure  --enable-tests --disable-optimization

# # Make sure the tests run against the newly installed environment
# (cd test/testdata && cabal clean && cabal configure)

# (cd test/testdata/cabal/cabal1 && cabal clean && cabal configure)
# (cd test/testdata/cabal/cabal2 && cabal clean && cabal configure)
# (cd test/testdata/cabal/cabal3 && cabal clean && cabal configure)
# (cd test/testdata/cabal/cabal4 && cabal clean && cabal configure)
# (cd test/testdata/cabal/foo    && cabal clean && cabal configure)

rm cabal.project.local
rm -fr dist*
# cabal-1.25 new-build --with-compiler=/opt/ghc/8.2.0.20170505/bin/ghc
# cabal-1.25 new-configure --with-compiler=/opt/ghc/8.2.0.20170507/bin/ghc --allow-newer
# cabal-1.25 new-configure --with-compiler=/opt/ghc/8.2.0.20170507/bin/ghc
cabal-1.25 new-configure --with-compiler=ghc-8.0.2 --enable-tests
