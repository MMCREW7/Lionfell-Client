#!/bin/sh
# Lionfell client launcher: installs a client binary downloaded by the updater
# (modules/updater: saved as otclient.new), then starts the client.
cd "$(dirname "$0")" || exit 1
if [ "$1" = "--updated" ]; then
    shift
    sleep 1 # let the old client finish exiting
fi
if [ -f otclient.new ]; then
    chmod +x otclient.new && mv -f otclient.new otclient
fi
exec ./otclient "$@"
