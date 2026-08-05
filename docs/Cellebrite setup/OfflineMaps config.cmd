@echo off
REM ---------------------------------------------------------------------------
REM Point Cellebrite Physical Analyzer / Reader at an osm-tirex tile server.
REM
REM EDIT THIS FIRST: the host name or IP of the machine running the tile server,
REM as reachable from this workstation. Keep the port as 8080 unless you changed
REM the published port in docker-compose.yml.
REM ---------------------------------------------------------------------------
set TILE_SERVER_HOST=tile-server.example.local
set TILE_SERVER_PORT=8080

REM Stop the TilesServer service
sc stop "TilesServer"

REM Disable the TilesServer service
sc config "TilesServer" start=disabled

echo TilesServer service stopped and disabled.

echo.
echo Setting up Registry key 'HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Cellebrite Mobile Data Secured'...

REM Add main key
reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Cellebrite Mobile Data Secured" /f

REM Add subkey and values
reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Cellebrite Mobile Data Secured\OfflineMaps" /v Path /t REG_SZ /d "C:\ProgramData\TileServerData" /f
reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Cellebrite Mobile Data Secured\OfflineMaps" /v Host /t REG_SZ /d "%TILE_SERVER_HOST%" /f
reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Cellebrite Mobile Data Secured\OfflineMaps" /v ServicePath /t REG_SZ /d "C:\ProgramData\TileServer" /f
reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Cellebrite Mobile Data Secured\OfflineMaps" /v Port /t REG_DWORD /d %TILE_SERVER_PORT% /f
reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Cellebrite Mobile Data Secured\OfflineMaps" /v Version /t REG_DWORD /d 7 /f
reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Cellebrite Mobile Data Secured\OfflineMaps" /v InstallationError /t REG_SZ /d "" /f
reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Cellebrite Mobile Data Secured\OfflineMaps" /v UseOfflineMaps /t REG_SZ /d "True" /f

echo.
echo Copying 'maps.mbtiles' to '%ProgramData%\TileServerData'...
copy maps.mbtiles %ProgramData%\TileServerData

echo.
@pause
