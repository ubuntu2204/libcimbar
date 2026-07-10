@echo off
REM ===================================================================
REM build_windows.bat — Build libcimbar.dll for Windows (x64)
REM
REM Prerequisites:
REM   - Visual Studio 2022 Build Tools
REM   - CMake 3.22+
REM   - OpenCV 4.5+ (set OPENCV_DIR)
REM   - vcpkg with glfw3 installed (optional, for window display)
REM
REM Usage:
REM   build_windows.bat [path-to-libcimbar-source]
REM
REM Example:
REM   build_windows.bat C:\project\libcimbar\libcimbar
REM ===================================================================

setlocal enabledelayedexpansion

echo.
echo ============================================================
echo  libcimbar Windows Build Script
echo ============================================================
echo.

REM ── Determine source path ──
if "%~1"=="" (
    set "LIBCIMBAR_SRC=C:\project\libcimbar\libcimbar"
) else (
    set "LIBCIMBAR_SRC=%~1"
)

if not exist "%LIBCIMBAR_SRC%\src\lib\encoder\Encoder.h" (
    echo ERROR: Cannot find libcimbar source at %LIBCIMBAR_SRC%
    echo Usage: build_windows.bat [path-to-libcimbar-source]
    exit /b 1
)

echo [1/5] Source path: %LIBCIMBAR_SRC%

REM ── Check for OpenCV ──
if "%OPENCV_DIR%"=="" (
    echo.
    echo WARNING: OPENCV_DIR is not set.
    echo Please set it to your OpenCV build directory, e.g.:
    echo   set OPENCV_DIR=C:\opencv\build
    echo.
    echo Attempting to find OpenCV via common paths...

    if exist "C:\opencv\build" (
        set "OPENCV_DIR=C:\opencv\build"
        echo Found OpenCV at C:\opencv\build
    ) else if exist "C:\tools\opencv\build" (
        set "OPENCV_DIR=C:\tools\opencv\build"
        echo Found OpenCV at C:\tools\opencv\build
    ) else if exist "C:\project\paddle_ocr\windows\third_party\opencv\include\opencv2\core.hpp" (
        set "OPENCV_DIR=C:\project\paddle_ocr\windows\third_party\opencv"
        echo Found OpenCV 4.9.0 at C:\project\paddle_ocr\windows\third_party\opencv
    ) else (
        echo ERROR: OpenCV not found. Please install OpenCV and set OPENCV_DIR.
        echo Download from: https://opencv.org/releases/
        exit /b 1
    )
)
echo [2/5] OpenCV: %OPENCV_DIR%

REM ── Check for vcpkg ──
set "VCPKG_TOOLCHAIN="
if exist "C:\vcpkg\scripts\buildsystems\vcpkg.cmake" (
    set "VCPKG_TOOLCHAIN=-DCMAKE_TOOLCHAIN_FILE=C:\vcpkg\scripts\buildsystems\vcpkg.cmake"
    echo [3/5] vcpkg: found at C:\vcpkg
) else (
    echo [3/5] vcpkg: not found (GLFW window display will be disabled)
)

REM ── Create build directory ──
set "BUILD_DIR=%~dp0build_windows"
if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
echo [4/5] Build dir: %BUILD_DIR%

REM ── Configure and build ──
echo [5/5] Configuring CMake...
echo.

cd /d "%BUILD_DIR%"

cmake "%~dp0" ^
    -G "Visual Studio 17 2022" ^
    -A x64 ^
    -DLIBCIMBAR_SRC="%LIBCIMBAR_SRC%" ^
    -DOPENCV_DIR="%OPENCV_DIR%" ^
    %VCPKG_TOOLCHAIN%

if %ERRORLEVEL% neq 0 (
    echo.
    echo ERROR: CMake configuration failed.
    exit /b 1
)

echo.
echo Building Release...
cmake --build . --config Release --parallel

if %ERRORLEVEL% neq 0 (
    echo.
    echo ERROR: Build failed.
    exit /b 1
)

echo.
echo ============================================================
echo  BUILD SUCCESSFUL
echo ============================================================
echo.
echo Output files:
echo   %BUILD_DIR%\Release\libcimbar.dll
echo   %BUILD_DIR%\Release\libcimbar.lib
echo.
echo Next steps:
echo   1. Copy libcimbar.dll to your Flutter app's Windows build output
echo      (example\build\windows\x64\runner\Release\)
echo   2. Also copy OpenCV DLLs from %OPENCV_DIR%\x64\vc16\bin\
echo.
echo Done.
