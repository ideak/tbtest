#!/bin/bash

TRACE_DIR=/sys/kernel/debug/tracing

cat $TRACE_DIR/trace_pipe
