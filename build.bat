@echo off
rem Builds the command line tool and the test runner with Delphi 12 (Win64).
setlocal
cd /d "%~dp0"
set DCC="C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\dcc64.exe"
if not exist bin mkdir bin
if not exist dcu mkdir dcu
%DCC% -B -Q -Ebin -NUdcu -Usource cli\abdeckercli.dpr || exit /b 1
move /y bin\abdeckercli.exe bin\abdecker.exe >nul || exit /b 1
%DCC% -B -Q -Ebin -NUdcu -Usource tests\abdeckertests.dpr || exit /b 1
copy /y cli\examples.bat bin\ >nul || exit /b 1
echo Build OK
