@echo off
rem Launcher of the wasm3das release bundle on Windows. The bundle root is the
rem directory holding this file: bin\daslang.exe, daslib\, app\, source\.
rem The daslang command line consumes --help and -h itself; use --wasm3-help.
setlocal
set "here=%~dp0"
"%here%bin\daslang.exe" "%here%app\wasm3.das" -- %*
