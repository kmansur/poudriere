#!/bin/sh
# Version: 1.19.0
# Native Poudriere plugin. Never return a failure to the builder.
# Only write a small event; the independent worker handles package files.
if [ -x /usr/local/bin/python3 ] && [ -r /usr/local/scripts/poudriere-beta/poudriere_publish.py ]; then
    /usr/local/bin/python3 /usr/local/scripts/poudriere-beta/poudriere_publish.py event bulk "$@" ||
        logger -t poudriere-progressive "Could not queue bulk event"
fi
exit 0
