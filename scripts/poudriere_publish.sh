#!/bin/sh
# Version: 1.19.0-beta.1
# Run independently from cron, never inside a Poudriere builder.
exec /usr/local/bin/python3 /usr/local/scripts/poudriere-beta/poudriere_publish.py publish
