#!/bin/sh
# API smoke tests against a real cratezig daemon, run as an unprivileged user.
# Covers everything that does not need root (starting containers does).
# Usage: tests/smoke.sh [path/to/cratezig]
set -u

BIN="${1:-zig-out/bin/cratezig}"
WORK="$(mktemp -d)"
SOCK=/tmp/cratezig.sock
PASS=0
FAIL=0

cleanup() {
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$WORK"
    rm -f "$SOCK"
}
trap cleanup EXIT

check() { # name expected actual
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL $1: expected [$2] got [$3]"
    fi
}

contains() { # name needle haystack
    case "$3" in
        *"$2"*) PASS=$((PASS + 1)) ;;
        *) FAIL=$((FAIL + 1)); echo "FAIL $1: [$2] not in [$3]" ;;
    esac
}

api() { curl -s --unix-socket "$SOCK" "$@"; }
code() { curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" "$@"; }

start_daemon() {
    "$BIN" daemon --config "$WORK/daemon.json" >>"$WORK/daemon.log" 2>&1 &
    PID=$!
    i=0
    until [ -S "$SOCK" ] && api http://d/_ping >/dev/null 2>&1; do
        i=$((i + 1))
        [ $i -gt 100 ] && { echo "daemon did not start"; cat "$WORK/daemon.log"; exit 1; }
        sleep 0.05
    done
}

stop_daemon() { kill "$PID"; wait "$PID" 2>/dev/null; rm -f "$SOCK"; PID=; }

printf '{"data-root":"%s/data","exec-root":"%s/run"}' "$WORK" "$WORK" >"$WORK/daemon.json"
rm -f "$SOCK"
start_daemon

# Test fixture: an image record without layers (no registry pulls yet).
IMGDIR="$WORK/data/image/overlay2/imagedb/content/sha256"
cat >"$IMGDIR/aaaabbbbcccc" <<'EOF'
{"Id":"sha256:aaaabbbbcccc","RepoTags":["testimg:latest"],"Config":{"Cmd":["echo","hi"],"Env":["PATH=/bin"]}}
EOF
stop_daemon
start_daemon

# --- HTTP layer ---
check "ping" "OK" "$(api http://d/_ping)"
check "head ping" "200" "$(code -I http://d/_ping)"
check "version prefix" "200" "$(code http://d/v1.43/version)"
check "too new api" "400" "$(code http://d/v1.99/version)"
check "unknown route" "404" "$(code http://d/v1.43/nope)"
check "method mismatch" "404" "$(code -X GET http://d/v1.43/containers/create)"
check "header too large" "431" "$(code -H "X-Big: $(head -c 70000 /dev/zero | tr '\0' a)" http://d/_ping)"
check "chunked body" "404" "$(printf '{"Image":"nope"}' | code -X POST -H 'Transfer-Encoding: chunked' -H 'Content-Type: application/json' --data-binary @- http://d/v1.43/containers/create)"
contains "keep-alive reuse" "Re-using existing" "$(curl -sv --unix-socket "$SOCK" http://d/_ping http://d/_ping 2>&1)"
contains "error shape" '"message":' "$(api http://d/v1.43/containers/nope/json)"

# --- containers ---
check "create" "201" "$(code -X POST -H 'Content-Type: application/json' -d '{"Image":"testimg","Cmd":null,"Labels":{"a":"b"},"HostConfig":{"RestartPolicy":{"Name":"always"}}}' 'http://d/v1.43/containers/create?name=web')"
check "duplicate name" "409" "$(code -X POST -H 'Content-Type: application/json' -d '{"Image":"testimg"}' 'http://d/v1.43/containers/create?name=web')"
check "bad name" "400" "$(code -X POST -H 'Content-Type: application/json' -d '{"Image":"testimg"}' 'http://d/v1.43/containers/create?name=bad%20name')"
contains "ps -a lists" '"Names":["/web"]' "$(api 'http://d/v1.43/containers/json?all=1')"
check "ps hides stopped" "[]" "$(api 'http://d/v1.43/containers/json')"
check "wait on created" '{"StatusCode":0,"Error":null}' "$(api -X POST http://d/v1.43/containers/web/wait)"

# wait?condition=removed must block until the container is deleted.
api -X POST 'http://d/v1.43/containers/web/wait?condition=removed' >"$WORK/wait.out" &
WAITPID=$!
sleep 0.2
check "wait blocks" "" "$(cat "$WORK/wait.out")"

# events: subscribe, then trigger a destroy.
api -N 'http://d/v1.43/events?filters=%7B%22event%22%3A%5B%22destroy%22%5D%7D' >"$WORK/events.out" &
EVPID=$!
sleep 0.2
check "rm -f" "204" "$(code -X DELETE 'http://d/v1.43/containers/web?force=1')"
wait "$WAITPID"
contains "wait released on rm" '"StatusCode"' "$(cat "$WORK/wait.out")"
sleep 0.2
kill "$EVPID" 2>/dev/null
contains "events stream" '"Action":"destroy"' "$(cat "$WORK/events.out")"

# --- honest 501s ---
check "build 501" "501" "$(code -X POST http://d/v1.43/build)"
check "import 501" "501" "$(code -X POST 'http://d/v1.43/images/create?fromSrc=-')"
check "bad reference" "400" "$(code -X POST 'http://d/v1.43/images/create?fromImage=UPPER')"

# --- volumes (regression: /volumes/{name} was mangled as a version prefix) ---
check "volume create" "201" "$(code -X POST -H 'Content-Type: application/json' -d '{"Name":"v1"}' http://d/v1.43/volumes/create)"
check "volume inspect" "200" "$(code http://d/v1.43/volumes/v1)"
check "volume rm" "204" "$(code -X DELETE http://d/v1.43/volumes/v1)"

# --- docker inspect shape ---
api -X POST -H 'Content-Type: application/json' -d '{"Image":"testimg","Entrypoint":["/bin/sh","-c"],"Cmd":["echo hi"]}' 'http://d/v1.43/containers/create?name=insp' >/dev/null
INSP="$(api http://d/v1.43/containers/insp/json)"
contains "inspect path" '"Path":"/bin/sh"' "$INSP"
contains "inspect args" '"Args":["-c","echo hi"]' "$INSP"
contains "inspect name" '"Name":"/insp"' "$INSP"
contains "inspect zero time" '"StartedAt":"0001-01-01T00:00:00Z"' "$INSP"
check "rm insp" "204" "$(code -X DELETE http://d/v1.43/containers/insp)"

# --- persistence across restart ---
check "net create" "201" "$(code -X POST -H 'Content-Type: application/json' -d '{"Name":"n1","IPAM":{"Config":[{"Subnet":"10.99.0.0/24"}]}}' http://d/v1.43/networks/create)"
api -X POST -H 'Content-Type: application/json' -d '{"Image":"testimg","Env":["A=1"]}' 'http://d/v1.43/containers/create?name=keep' >/dev/null
BRIDGE1="$(api http://d/v1.43/networks/bridge | head -c 90)"
stop_daemon
start_daemon
contains "container persisted" '"A=1"' "$(api http://d/v1.43/containers/keep/json)"
contains "network persisted" '"Subnet":"10.99.0.0/24"' "$(api http://d/v1.43/networks/n1)"
check "bridge id stable" "$BRIDGE1" "$(api http://d/v1.43/networks/bridge | head -c 90)"

# --- stock docker CLI, when installed ---
if command -v docker >/dev/null 2>&1; then
    export DOCKER_HOST="unix://$SOCK"
    contains "docker version" "API version:      1.43" "$(docker version 2>&1)"
    contains "docker ps -a" "keep" "$(docker ps -a 2>&1)"
    check "docker inspect" "/keep created" "$(docker inspect -f '{{.Name}} {{.State.Status}}' keep 2>&1)"
    contains "docker network ls" "n1" "$(docker network ls 2>&1)"
    contains "docker pull" "alpine:latest" "$(docker pull alpine 2>&1)"
    check "docker rm" "keep" "$(docker rm keep 2>&1)"
fi

# --- registry pulls (needs network; skip with CRATEZIG_SMOKE_OFFLINE=1) ---
if [ "${CRATEZIG_SMOKE_OFFLINE:-0}" != 1 ]; then
    LAYERS_BEFORE="$(find "$WORK/data/overlay2" -maxdepth 1 -mindepth 1 ! -name l | wc -l | tr -d ' ')"
    PULL="$(api -X POST 'http://d/v1.43/images/create?fromImage=busybox&tag=latest')"
    contains "pull busybox" "Downloaded newer image for busybox:latest" "$PULL"
    contains "pull progress" '"status":"Pull complete"' "$PULL"
    contains "pulled image listed" '"busybox:latest"' "$(api http://d/v1.43/images/json)"
    contains "image config kept" '"Cmd":["sh"]' "$(api http://d/v1.43/images/busybox/json)"
    contains "pull again" "Image is up to date for busybox:latest" "$(api -X POST 'http://d/v1.43/images/create?fromImage=busybox&tag=latest')"
    contains "pull missing" "pull access denied" "$(api -X POST 'http://d/v1.43/images/create?fromImage=cratezig-does-not-exist-xyz&tag=nope')"
    api -X POST -H 'Content-Type: application/json' -d '{"Image":"busybox"}' 'http://d/v1.43/containers/create?name=bb' >/dev/null
    check "rmi in use" "409" "$(code -X DELETE http://d/v1.43/images/busybox)"
    check "rm bb" "204" "$(code -X DELETE http://d/v1.43/containers/bb)"
    check "rmi" "200" "$(code -X DELETE http://d/v1.43/images/busybox)"
    check "layers collected" "$LAYERS_BEFORE" "$(find "$WORK/data/overlay2" -maxdepth 1 -mindepth 1 ! -name l | wc -l | tr -d ' ')"
fi

echo "smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
