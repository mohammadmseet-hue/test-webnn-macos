#!/bin/bash
# Run WebNN pool2d ceil rounding PoC tests on Chrome Canary (macOS)

CHROME="/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"
TESTDIR="/tmp/webnn-pool2d-test"
RESULTSDIR="/tmp/webnn-pool2d-results"
PORT=8765

mkdir -p "$RESULTSDIR"

# Kill any existing Chrome/server instances
pkill -f "Google Chrome Canary" 2>/dev/null || true
pkill -f "python3 -m http.server $PORT" 2>/dev/null || true
sleep 2

# Start HTTP server
cd "$TESTDIR"
python3 -m http.server $PORT &
HTTP_PID=$!
sleep 1
echo "HTTP server started on port $PORT (PID: $HTTP_PID)"

run_test() {
    local poc_name="$1"
    local poc_file="$2"
    local max_wait="${3:-30}"

    echo ""
    echo "=========================================="
    echo "Running: $poc_name"
    echo "=========================================="

    local userdir="/tmp/chrome-webnn-$$-$poc_name"
    mkdir -p "$userdir"

    # Run Chrome headless with WebNN
    "$CHROME" \
        --headless=new \
        --no-first-run \
        --no-default-browser-check \
        --disable-gpu-sandbox \
        --enable-features=WebMachineLearningNeuralNetwork \
        --enable-logging=stderr \
        --v=0 \
        --user-data-dir="$userdir" \
        --dump-dom \
        --virtual-time-budget=15000 \
        "http://localhost:$PORT/$poc_file" \
        > "$RESULTSDIR/${poc_name}-dom.txt" 2> "$RESULTSDIR/${poc_name}-stderr.txt" &

    local chrome_pid=$!

    # Wait with timeout
    local elapsed=0
    while kill -0 $chrome_pid 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [ $elapsed -ge $max_wait ]; then
            echo "TIMEOUT after ${max_wait}s - killing Chrome"
            kill -9 $chrome_pid 2>/dev/null
            wait $chrome_pid 2>/dev/null
            break
        fi
    done

    wait $chrome_pid 2>/dev/null
    local exit_code=$?

    echo "Exit code: $exit_code (elapsed: ${elapsed}s)"

    if [ $exit_code -eq 137 ] || [ $exit_code -eq 139 ] || [ $exit_code -eq 134 ]; then
        echo "*** CRASH SIGNAL DETECTED (exit $exit_code) ***"
    fi

    echo "--- DOM Output ---"
    cat "$RESULTSDIR/${poc_name}-dom.txt" 2>/dev/null | head -120

    echo "--- Relevant stderr ---"
    grep -iE "(crash|abort|signal|ASAN|overflow|corrupt|segfault|ERROR|WebNN|MLContext|pool2d|fatal|CHECK|DCHECK)" \
        "$RESULTSDIR/${poc_name}-stderr.txt" 2>/dev/null | head -40

    rm -rf "$userdir"
    return $exit_code
}

run_test "poc1-basic" "poc1-basic-ceil-rounding.html" 45
run_test "poc2-odd-sizes" "poc2-odd-sizes.html" 45
run_test "poc3-large-tensors" "poc3-large-tensors.html" 60
run_test "poc4-padding" "poc4-padding-variations.html" 45
run_test "poc5-crash" "poc5-crash-trigger.html" 120

echo ""
echo "=========================================="
echo "ALL TESTS COMPLETE"
echo "=========================================="
ls -la "$RESULTSDIR/"

kill $HTTP_PID 2>/dev/null
echo "Done."
