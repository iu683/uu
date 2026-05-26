#!/bin/bash

SNIS=(
amd.com
apps.mzstatic.com
aws.com
azure.microsoft.com
beacon.gtv-pub.com
bing.com
catalog.gamepass.com
cdn.bizibly.com
cdn-dynmedia-1.microsoft.com
devblogs.microsoft.com
fpinit.itunes.apple.com
go.microsoft.com
gray-config-prod.api.arc-cdn.net
gray.video-player.arcpublishing.com
images.nvidia.com
r.bing.com
services.digitaleast.mobi
snap.licdn.com
statici.icloud.com
tag.demandbase.com
tag-logger.demandbase.com
ts1.tc.mm.bing.net
ts2.tc.mm.bing.net
vs.aws.amazon.com
www.apple.com
www.icloud.com
www.microsoft.com
www.oracle.com
www.xbox.com
www.xilinx.com
xp.apple.com
)

BEST_SNI=""
BEST_TIME=999999

echo "Start SNI benchmark..."

for sni in "${SNIS[@]}"; do
  start=$(date +%s%N)

  timeout 3 openssl s_client \
    -connect ${sni}:443 \
    -servername ${sni} \
    -brief </dev/null >/dev/null 2>&1

  if [ $? -eq 0 ]; then
    end=$(date +%s%N)
    cost=$(( (end - start) / 1000000 ))

    echo "$sni -> ${cost}ms"

    if [ $cost -lt $BEST_TIME ]; then
      BEST_TIME=$cost
      BEST_SNI=$sni
    fi
  else
    echo "$sni -> FAIL"
  fi
done

echo "===================="
echo "优选 SNI: $BEST_SNI"
echo "TIME: ${BEST_TIME}ms"
