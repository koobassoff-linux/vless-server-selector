#!/bin/env bash

#PORT=$(netstat -epln 2>/dev/null | grep xray | awk  '{print $4}' | cut -d: -f2 | sort | head -n 1)

export HTTPS_PROXY=127.0.0.1:10808
export https_proxy=127.0.0.1:10808
export HTTP_PROXY=127.0.0.1:10808
export http_proxy=127.0.0.1:10808
export FTP_PROXY=127.0.0.1:10808
export ftp_proxy=127.0.0.1:10808
export ALL_PROXY=127.0.0.1:10808
export all_proxy=127.0.0.1:10808
