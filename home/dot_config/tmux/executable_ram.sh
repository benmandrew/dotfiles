#!/bin/sh
awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{
    printf "%4.1fG/%4.1fG\n", (t-a)/1048576, t/1048576
}' /proc/meminfo
