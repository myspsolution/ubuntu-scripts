@echo off
SET "commitMsg=%~1"
IF "%commitMsg%"=="" (
    echo Commit message is mandatory.
    exit /b 1
)
git pull origin main
git add .
git commit -m "%commitMsg%"
git push origin main
