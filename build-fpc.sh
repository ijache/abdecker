#!/bin/sh
# Builds the command line tool and the test runner with Free Pascal 3.2.2:
# Linux, macOS, Windows (64 bit, from Git Bash). Result in bin/ as with
# build.bat (the last build wins); compiled units in lib/<cpu>-<os>/.
#   FPC=<path> sh build-fpc.sh    another compiler
set -e
cd "$(dirname "$0")"
FPC=${FPC:-fpc}
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) TARGET="-Px86_64 -Twin64"; EXE=.exe ;;
  *) TARGET=""; EXE="" ;;
esac
UNITS=lib/$($FPC $TARGET -iTP)-$($FPC $TARGET -iTO)
mkdir -p bin "$UNITS"
# -B: always everything; -vewn: errors, warnings, notes (no hints), without
# 4104/4105 (implicit string conversion: intended, string holds UTF-8) and
# 5089/5093 (managed variable "not initialized": always is)
OPTS="$TARGET -B -O2 -vewn -vm4104,4105,5089,5093 -FU$UNITS -FEbin -Fusource -Fucli"
# cli/abdeckercli.dpr, not abdecker.dpr: program and unit abdecker would
# both yield abdecker.o
$FPC $OPTS cli/abdeckercli.dpr
mv -f bin/abdeckercli$EXE bin/abdecker$EXE
$FPC $OPTS tests/abdeckertests.dpr
[ -n "$EXE" ] && cp -f cli/examples.bat bin/
echo Build OK
