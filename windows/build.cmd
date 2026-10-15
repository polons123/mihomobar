@echo off
rem Сборка MihomoBar для Windows штатным csc.exe из .NET Framework 4 (SDK не нужен).
rem Ядро и wintun кладутся в dist\core\{x64,arm64} (см. README.md). Версия берётся из ..\VERSION.
cd /d "%~dp0"
if not exist dist mkdir dist
if not exist obj mkdir obj
set /p VER=<..\VERSION
set VER=%VER: =%
> obj\version.cs echo [assembly: System.Reflection.AssemblyVersion("%VER%.0")]
>> obj\version.cs echo [assembly: System.Reflection.AssemblyFileVersion("%VER%.0")]
"%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /platform:anycpu /codepage:65001 /optimize+ /out:dist\MihomoBar.exe /win32manifest:app.manifest /win32icon:app.ico /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll MihomoBar.cs obj\version.cs
