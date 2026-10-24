#!/usr/bin/env bash
cd ~/.minecraft || exit 1
exec java -jar ~/.minecraft/SKlauncher-3.2.18.jar "$@"
