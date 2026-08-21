@echo off
rem ---------------------------------------------------------------------
rem  True Borderless - Steam launch options wrapper
rem
rem  Paste this into Steam:
rem
rem    Library > Project Zomboid > right click > Properties >
rem    General > Launch Options:
rem
rem      "<full path to this file>" %command%
rem
rem  Keep the quotes. After that it does not matter how you start the
rem  game -- the Play button, a desktop shortcut, Big Picture, a steam://
rem  link -- Steam always comes through here first. No background service,
rem  nothing to remember, nothing to start by hand.
rem
rem  What it does, in order:
rem    1. Puts options.ini into the right state and turns off Windows
rem       Fullscreen Optimizations for the game. Idempotent: running it a
rem       hundred times is the same as running it once.
rem    2. Starts the helper, which waits for the game window, strips its
rem       frame and parks it one pixel off every edge of the monitor so
rem       Windows will not promote it to the fullscreen presentation path.
rem       That one pixel is what makes alt-tab seamless. It exits by
rem       itself when the game closes.
rem    3. Starts the game AND WAITS for it. The waiting matters: it is
rem       what keeps Steam counting playtime and the overlay working.
rem
rem  Full guide: https://github.com/watskybelfort/pz-true-borderless
rem ---------------------------------------------------------------------
setlocal

set "HERE=%~dp0"

rem %~dp1 is the folder of the first argument, i.e. the game executable
rem Steam just substituted into %command%. That makes the install path a
rem known fact rather than something the helper has to go looking for.
rem
rem It arrives with a trailing backslash, and "C:\some\path\" would escape
rem the closing quote and corrupt the whole command line, so drop it.
set "GAMEDIR=%~dp1"
if defined GAMEDIR if "%GAMEDIR:~-1%"=="\" set "GAMEDIR=%GAMEDIR:~0,-1%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%TrueBorderless.ps1" -Mode Seamless -GamePath "%GAMEDIR%"

rem -WaitSeconds bounds the wait. Without it, a launch that never reaches
rem the game would leave the helper waiting forever for a window that is
rem never going to exist, and you would have to kill it by hand. With it
rem the helper gives up on its own. Five minutes is plenty even booting a
rem heavy mod list off a slow disk.
start "True Borderless" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%TrueBorderless.ps1" -Mode Watch -WaitSeconds 300

rem Project Zomboid's classpath is relative (".;projectzomboid.jar"), so
rem the game only starts if the working directory is its own folder. Steam
rem already sets that, but running this .bat by hand from somewhere else
rem would kill it with "Failed to find class: zombie/gameStates/MainScreenState".
if defined GAMEDIR if exist "%GAMEDIR%" pushd "%GAMEDIR%"

rem %* is the %command% Steam substituted: the executable path plus its
rem arguments. Running it plain launches it and blocks until it exits.
%*

if defined GAMEDIR if exist "%GAMEDIR%" popd

endlocal
