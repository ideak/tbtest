#!/bin/bash

TRACE_DIR=/sys/kernel/debug/tracing

echo 1 > $TRACE_DIR/events/thunderbolt/enable
