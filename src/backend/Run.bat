@echo off
%JRE_BIN_DIR%\java.exe -Dmydlp.appdir=%MYDLP_APPDIR% -cp %BACKEND_DIR%\tika-xps.jar;%BACKEND_DIR%\mydlp-backend.jar com.mydlp.backend.Main
