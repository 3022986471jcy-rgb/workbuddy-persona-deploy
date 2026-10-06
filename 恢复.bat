@echo off
title WorkBuddy 人格恢复
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" restore menu
echo.
echo 任务结束，按任意键关闭窗口...
pause >nul
exit /b
