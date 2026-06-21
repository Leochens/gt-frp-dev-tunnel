@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PY_SCRIPT=%SCRIPT_DIR%frp_dev_tunnel.py"

where py >nul 2>nul
if %ERRORLEVEL%==0 (
  py -3 -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)" >nul 2>nul
  if %ERRORLEVEL%==0 (
    py -3 "%PY_SCRIPT%" %*
    exit /b %ERRORLEVEL%
  )
)

where python >nul 2>nul
if %ERRORLEVEL%==0 (
  python -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)" >nul 2>nul
  if %ERRORLEVEL%==0 (
    python "%PY_SCRIPT%" %*
    exit /b %ERRORLEVEL%
  )
)

echo error: Python 3.8+ is required.
where winget >nul 2>nul
if %ERRORLEVEL%==0 (
  echo Install with: winget install -e --id Python.Python.3.12
) else (
  echo Install Python 3.8+ first, then rerun this command.
)
exit /b 1
