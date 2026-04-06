#!/bin/bash
# Run WebNN tests using Chrome with remote debugging

CHROME="/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"
TESTDIR="/tmp/webnn-pool2d-test"
PORT=8767
RDP_PORT=9333

pkill -f "Google Chrome Canary" 2>/dev/null
pkill -f "python3 -m http.server $PORT" 2>/dev/null
sleep 2

cd "$TESTDIR"
python3 -m http.server $PORT &
HTTP_PID=$!
sleep 1

run_rdp_test() {
    local name="$1"
    local file="$2"
    local wait_secs="${3:-20}"

    echo ""
    echo "=========================================="
    echo "Testing: $name"
    echo "=========================================="

    pkill -f "Google Chrome Canary" 2>/dev/null
    sleep 2
    rm -rf /tmp/chrome-rdp-$name

    "$CHROME" \
        --headless=new \
        --no-first-run \
        --no-default-browser-check \
        --disable-gpu-sandbox \
        --enable-features=WebMachineLearningNeuralNetwork \
        --remote-debugging-port=$RDP_PORT \
        --enable-logging=stderr \
        --v=0 \
        --user-data-dir="/tmp/chrome-rdp-$name" \
        "http://localhost:$PORT/$file" \
        2>"/tmp/rdp-${name}-stderr.txt" &

    CPID=$!
    echo "Chrome PID: $CPID"

    # Wait for Chrome to process
    sleep $wait_secs

    # Check if Chrome is still running
    if kill -0 $CPID 2>/dev/null; then
        echo "Chrome still alive after ${wait_secs}s"

        # Try to get page DOM via CDP
        WS_URL=$(curl -s http://localhost:$RDP_PORT/json 2>/dev/null | python3 -c "
import json, sys
try:
    pages = json.load(sys.stdin)
    for p in pages:
        if 'webSocketDebuggerUrl' in p:
            print(p['webSocketDebuggerUrl'])
            break
except:
    pass
" 2>/dev/null)
        echo "WS: $WS_URL"

        # Get page content via CDP HTTP endpoint
        PAGE_ID=$(curl -s http://localhost:$RDP_PORT/json 2>/dev/null | python3 -c "
import json, sys
try:
    pages = json.load(sys.stdin)
    for p in pages:
        print(p.get('id', ''))
        break
except:
    pass
" 2>/dev/null)

        if [ -n "$PAGE_ID" ]; then
            # Execute JS to get our output
            curl -s "http://localhost:$RDP_PORT/json/protocol" > /dev/null 2>&1

            # Use CDP to evaluate JS and get output
            python3 -c "
import json, asyncio, websockets, sys

async def get_output():
    ws_url = '$WS_URL'
    if not ws_url:
        print('No WebSocket URL')
        return
    try:
        async with websockets.connect(ws_url) as ws:
            # Get document content
            await ws.send(json.dumps({
                'id': 1,
                'method': 'Runtime.evaluate',
                'params': {'expression': 'document.getElementById(\"output\")?.textContent || \"no output element\"'}
            }))
            resp = await asyncio.wait_for(ws.recv(), timeout=5)
            data = json.loads(resp)
            result = data.get('result', {}).get('result', {}).get('value', 'no value')
            print(result)
    except Exception as e:
        print(f'CDP error: {e}')

asyncio.run(get_output())
" 2>/dev/null || echo "CDP query failed (websockets module may not be installed)"
        fi

        kill $CPID 2>/dev/null
        wait $CPID 2>/dev/null
        echo "Chrome killed"
    else
        wait $CPID 2>/dev/null
        EC=$?
        echo "Chrome exited with code: $EC"
        if [ $EC -eq 139 ] || [ $EC -eq 134 ] || [ $EC -eq 137 ]; then
            echo "*** CRASH SIGNAL ***"
        fi
    fi

    echo "--- Console output ---"
    grep "CONSOLE" "/tmp/rdp-${name}-stderr.txt" 2>/dev/null | sed 's/.*CONSOLE[^"]*"//' | sed 's/", source:.*//'

    echo "--- Crash signals ---"
    grep -iE "crash|mach_vm_read|abort|ASAN|CHECK.failed|DCHECK" "/tmp/rdp-${name}-stderr.txt" 2>/dev/null | head -5

    rm -rf "/tmp/chrome-rdp-$name"
}

# Run tests
run_rdp_test "control" "control-test.html" 10
run_rdp_test "poc6-pinpoint" "poc6-pinpoint.html" 25
run_rdp_test "poc1-basic" "poc1-basic-ceil-rounding.html" 25

echo ""
echo "=========================================="
echo "ALL DONE"
echo "=========================================="

kill $HTTP_PID 2>/dev/null
pkill -f "Google Chrome Canary" 2>/dev/null
