#!/bin/sh


if [ ! -d /var/gemclient.data/publish ]; then
	echo "create /var/gemclient.data/publish for storing public gem files"
	mkdir -p /var/gemclient.data/publish
fi


