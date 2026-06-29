#!/bin/sh
read -r _ u n s id iw ir sr st gu gnu < /proc/stat
sleep 0.2
read -r _ u2 n2 s2 id2 iw2 ir2 sr2 st2 gu2 gnu2 < /proc/stat
t=$((u + n + s + id + iw + ir + sr + st))
t2=$((u2 + n2 + s2 + id2 + iw2 + ir2 + sr2 + st2))
echo $((100 - (id2 - id) * 100 / (t2 - t)))
