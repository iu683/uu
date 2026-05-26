#!/bin/bash

SNIS=(
amd.com
apps.mzstatic.com
aws.com
azure.microsoft.com
bing.com
cdn-dynmedia-1.microsoft.com
fpinit.itunes.apple.com
go.microsoft.com
images.nvidia.com
www.apple.com
www.microsoft.com
www.xbox.com
)

BEST_SNI=""
BEST_TIME=999999

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
