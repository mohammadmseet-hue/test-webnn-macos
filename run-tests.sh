#!/bin/bash
# Run WebNN pool2d ceil rounding PoC tests on Chrome Canary via macOS

CHROME="/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"
TESTDIR="/tmp/webnn-pool2d-test"
RESULTSDIR="/tmp/webnn-pool2d-results"
PORT=8765

mkdir -p "$RESULTSDIR"

# Kill any existing Chrome instances
pkill -f "Google Chrome Canary" 2>/dev/null || true
sleep 2

# Start a simple HTTP server for the test files
cd "$TESTDIR"
python3 -m http.server $PORT &
HTTP_PID=$!
sleep 1

echo "HTTP server started on port $PORT (PID: $HTTP_PID)"

run_test() {
    local poc_name="$1"
    local poc_file="$2"
    local timeout="${3:-30}"

    echo ""
    echo "=========================================="
    echo "Running: $poc_name"
    echo "=========================================="

    # Create a user data dir for this test
    local userdir="/tmp/chrome-webnn-$$-$poc_name"
    mkdir -p "$userdir"

    # Run Chrome with WebNN enabled, capture console output
    timeout ${timeout}s "$CHROME" \
        --headless=new \
        --no-first-run \
        --no-default-browser-check \
        --disable-gpu-sandbox \
        --enable-features=WebMachineLearningNeuralNetwork \
        --enable-logging=stderr \
        --v=1 \
        --user-data-dir="$userdir" \
        --dump-dom \
        "http://localhost:$PORT/$poc_file" \
        > "$RESULTSDIR/${poc_name}-dom.txt" 2> "$RESULTSDIR/${poc_name}-stderr.txt"

    local exit_code=$?

    echo "Exit code: $exit_code"

    if [ $exit_code -eq 124 ]; then
        echo "TIMEOUT after ${timeout}s"
    elif [ $exit_code -ne 0 ] && [ $exit_code -ne 124 ]; then
        echo "*** NON-ZERO EXIT: $exit_code (possible crash!) ***"
    fi

    # Show DOM output (contains our log messages)
    echo "--- DOM Output ---"
    cat "$RESULTSDIR/${poc_name}-dom.txt" 2>/dev/null | head -100

    # Check stderr for crashes
    echo "--- Relevant stderr ---"
    grep -iE "(crash|abort|signal|ASAN|overflow|corrupt|segfault|ERROR|WebNN|MLContext|pool2d|fatal)" \
        "$RESULTSDIR/${poc_name}-stderr.txt" 2>/dev/null | head -30

    # Cleanup user dir
    rm -rf "$userdir"

    return $exit_code
}

# Run each PoC
run_test "poc1-basic" "poc1-basic-ceil-rounding.html" 30
run_test "poc2-odd-sizes" "poc2-odd-sizes.html" 30
run_test "poc3-large-tensors" "poc3-large-tensors.html" 60
run_test "poc4-padding" "poc4-padding-variations.html" 30
run_test "poc5-crash" "poc5-crash-trigger.html" 90

echo ""
echo "=========================================="
echo "ALL TESTS COMPLETE"
echo "=========================================="
echo "Results in: $RESULTSDIR/"
ls -la "$RESULTSDIR/"

# Cleanup
kill $HTTP_PID 2>/dev/null
echo "Done."
