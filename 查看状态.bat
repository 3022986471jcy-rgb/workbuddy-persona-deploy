@echo off
title WorkBuddy 部署状态
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" status menu
echo.
echo 任务结束，按任意键关闭窗口...
pause >nul
exit /b
