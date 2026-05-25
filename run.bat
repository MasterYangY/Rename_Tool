@echo off
chcp 65001 >nul
title 批量重命名工具
cd /d "%~dp0"

rem 通过 UTF-8 显式读取脚本内容并执行，避免中文乱码
powershell -NoProfile -ExecutionPolicy Bypass -STA -Command "& { try { $c = [System.IO.File]::ReadAllText((Join-Path $PWD 'BatchRename.ps1'), [System.Text.Encoding]::UTF8); Invoke-Expression $c } catch { Write-Host $_.Exception.Message -ForegroundColor Red; pause } }"

if errorlevel 1 (
    echo.
    echo 程序运行出现异常，请按任意键关闭...
    pause >nul
)
