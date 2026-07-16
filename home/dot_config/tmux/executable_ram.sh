#!/bin/sh
awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{
    printf "%5.1fG/%5.1fG\n", (t-a)/1048576, t/1048576
}' /proc/meminfo
