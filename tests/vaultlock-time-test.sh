#!/usr/bin/env bash
# Test deadline presentation without inspecting or changing a vault.
set -euo pipefail

VL=${1:-$(cd "$(dirname "$0")/.." && pwd)/bin/vaultlock}
fail=0
checks=0

check() { # description expected actual
  checks=$(( checks + 1 ))
  if [[ "$2" == "$3" ]]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

format_time() {
  VAULTLOCK_TEST_FAKE_SYSTEM=1 /bin/bash "$VL" __format_time "$@"
}

check_format() { # description expected timezone fixture arguments...
  local description=$1 expected=$2 timezone=$3 actual status
  shift 3
  if actual=$(TZ="$timezone" format_time "$@" 2>&1); then
    status=0
  else
    status=$?
  fi
  check "$description exits successfully" 0 "$status"
  check "$description" "$expected" "$actual"
}

epoch() {
  TZ=UTC0 /bin/date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s
}

now=1000000
while IFS='|' read -r seconds expected; do
  check_format "remaining duration $seconds seconds" "$expected" UTC0 \
    remaining "$(( now + seconds ))" "$now"
done <<'CASES'
-1|deadline passed
0|deadline passed
1|1s
42|42s
59|59s
60|1m
61|1m
3599|59m
3600|1h
3660|1h 1m
86399|23h 59m
86400|1d
86460|1d 1m
90000|1d 1h
183840|2d 3h 4m
183899|2d 3h 4m
CASES

now=$(epoch '2026-09-01 00:00:00')
check_format 'deadline includes local date and offset' \
  '2026-09-01 02:00:42 +0200 (in 42s)' Europe/Amsterdam \
  deadline "$(( now + 42 ))" "$now"
check_format 'deadline uses UTC when selected' \
  '2026-09-01 00:00:42 +0000 (in 42s)' UTC0 \
  deadline "$(( now + 42 ))" "$now"
check_format 'deadline uses a western timezone and previous date' \
  '2026-08-31 17:00:42 -0700 (in 42s)' America/Los_Angeles \
  deadline "$(( now + 42 ))" "$now"
check_format 'deadline supports a half-hour offset' \
  '2026-09-01 05:30:42 +0530 (in 42s)' Asia/Kolkata \
  deadline "$(( now + 42 ))" "$now"
check_format 'deadline formats multiple units' \
  '2026-09-03 03:04:00 +0000 (in 2d 3h 4m)' UTC0 \
  deadline "$(( now + 183840 ))" "$now"
check_format 'deadline at captured now has passed' \
  '2026-09-01 00:00:00 +0000 (deadline passed)' UTC0 \
  deadline "$now" "$now"
check_format 'deadline before captured now has passed' \
  '2026-08-31 23:59:59 +0000 (deadline passed)' UTC0 \
  deadline "$(( now - 1 ))" "$now"

now=$(epoch '2026-12-31 23:30:00')
check_format 'deadline crosses the year without changing elapsed time' \
  '2027-01-01 00:30:00 +0000 (in 1h)' UTC0 \
  deadline "$(( now + 3600 ))" "$now"

now=$(epoch '2026-03-29 00:30:00')
check_format 'spring DST jump uses elapsed seconds' \
  '2026-03-29 03:30:00 +0200 (in 1h)' Europe/Amsterdam \
  deadline "$(( now + 3600 ))" "$now"
now=$(epoch '2026-03-28 11:00:00')
check_format 'spring local calendar day lasts 23 hours' \
  '2026-03-29 12:00:00 +0200 (in 23h)' Europe/Amsterdam \
  deadline "$(( now + 23 * 3600 ))" "$now"
check_format 'spring duration day remains 86400 seconds' \
  '2026-03-29 13:00:00 +0200 (in 1d)' Europe/Amsterdam \
  deadline "$(( now + 86400 ))" "$now"

now=$(epoch '2026-10-25 00:30:00')
check_format 'autumn repeated clock time uses elapsed seconds' \
  '2026-10-25 02:30:00 +0100 (in 1h)' Europe/Amsterdam \
  deadline "$(( now + 3600 ))" "$now"
check_format 'autumn first repeated clock time keeps summer offset' \
  '2026-10-25 02:30:00 +0200 (in 30m)' Europe/Amsterdam \
  deadline "$now" "$(( now - 1800 ))"
now=$(epoch '2026-10-24 10:00:00')
check_format 'autumn local calendar day lasts 25 hours' \
  '2026-10-25 12:00:00 +0100 (in 1d 1h)' Europe/Amsterdam \
  deadline "$(( now + 25 * 3600 ))" "$now"

check_format 'unsupported local date retains epoch and relative duration' \
  'epoch 999999999999999999 (local timestamp unavailable) (in 11574074074062d 11h 59m)' \
  UTC0 deadline 999999999999999999 1000000
check_format 'unsupported local date retains passed deadline' \
  'epoch 999999999999999999 (local timestamp unavailable) (deadline passed)' \
  UTC0 deadline 999999999999999999 999999999999999999

while IFS='|' read -r notation expected; do
  json_epoch=$(printf '%s\n' "$notation" | jq -r tostring)
  check_format "JSON epoch $notation uses exact integer arithmetic" "$expected" UTC0 \
    remaining "$json_epoch" 0
done <<'CASES'
1.0|1s
1e3|16m
1E+17|1157407407407d 9h 46m
CASES

check_format 'decimal epoch formats canonical local time' \
  '1970-01-01 00:00:01 +0000 (in 1s)' UTC0 deadline 1.0 0
check_format 'scientific epoch formats canonical local time' \
  '1970-01-01 00:16:40 +0000 (in 1s)' UTC0 deadline 1e3 9.99e2
check_format 'fractional mantissa shifts exactly' '2m' UTC0 remaining 1.25e2 0
check_format 'negative exponent shifts exactly' '1s' UTC0 remaining 1000e-3 0
check_format 'decimal shift preserves all eighteen integer digits' \
  '1s' UTC0 remaining 9.99999999999999999e17 999999999999999998
check_format 'zero does not overflow a large exponent' 'deadline passed' UTC0 \
  remaining 0e999999999999999999999 0
check_format 'nonintegral target has explicit unavailable duration' \
  'remaining time unavailable' UTC0 remaining 1.5 0
check_format 'nonintegral current time has explicit unavailable duration' \
  '1970-01-01 00:00:01 +0000 (remaining time unavailable)' UTC0 deadline 1 0.5
check_format 'unsupported integral range has explicit unavailable duration' \
  'epoch 1000000000000000000 (local timestamp unavailable) (remaining time unavailable)' \
  UTC0 deadline 1000000000000000000 0
check_format 'unsupported exponent has explicit unavailable duration' \
  'epoch 1e1000 (local timestamp unavailable) (remaining time unavailable)' UTC0 \
  deadline 1e1000 0

for unsafe_epoch in 'not-an-epoch' '1+2' '-1'; do
  if output=$(format_time deadline "$unsafe_epoch" 1000000 2>&1); then
    status=0
  else
    status=$?
  fi
  check "unsafe target epoch $unsafe_epoch is rejected" 64 "$status"
  check "unsafe target epoch $unsafe_epoch reports validation failure" \
    'vaultlock: invalid test target epoch' "$output"
  if output=$(format_time deadline 1000000 "$unsafe_epoch" 2>&1); then
    status=0
  else
    status=$?
  fi
  check "unsafe current epoch $unsafe_epoch is rejected" 64 "$status"
  check "unsafe current epoch $unsafe_epoch reports validation failure" \
    'vaultlock: invalid test current epoch' "$output"
done

target=$(( $(/bin/date +%s) + 3599 ))
check_format 'remaining duration defaults to current time' '59m' UTC0 \
  remaining "$target"
stamp=$(TZ=UTC0 /bin/date -j -r "$target" '+%Y-%m-%d %H:%M:%S %z')
check_format 'normal lock result uses effective epoch and fresh current time' \
  "Result: locked until $stamp (in 59m)" UTC0 lock_result 0 "$target"
check_format 'verbose lock result retains drand round' \
  "Result: locked until $stamp (in 59m) (drand round 31805812)" UTC0 \
  lock_result 1 "$target"
check_format 'very verbose lock result retains drand round' \
  "Result: locked until $stamp (in 59m) (drand round 31805812)" UTC0 \
  lock_result 2 "$target"

if output=$(VAULTLOCK_TEST_FAKE_SYSTEM=0 /bin/bash "$VL" \
    __format_time remaining 1000000 1000000 2>&1); then
  status=0
else
  status=$?
fi
check 'formatting fixture is disabled outside fake system' 64 "$status"
check 'disabled formatting fixture reports unknown command' \
  'vaultlock: unknown command: __format_time' "$output"

printf '%s checks, failure status %s\n' "$checks" "$fail"
exit "$fail"
