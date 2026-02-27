#!/usr/bin/env bash

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

exec julia --project=/Users/kburke/.julia/packages/LanguageServer/Fwm1f -e 'using LanguageServer; runserver();'
