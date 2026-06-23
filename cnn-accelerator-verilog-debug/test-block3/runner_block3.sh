#!/bin/bash

set -euo pipefail

# ============================================================
# CONFIG
# ============================================================

SIM_OUT="sim3.out"
TOP_MODULE="tb_block3_dump"

# MEM_ROOT="mem"
MEM_ROOT="mem-test"
CSV_ROOT="csv-results"

# ============================================================
# COMPILE
# ============================================================

echo "============================================"
echo "Compiling Block3 testbench..."
echo "Top module : ${TOP_MODULE}"
echo "Output     : ${SIM_OUT}"
echo "============================================"

iverilog -g2012 -s "$TOP_MODULE" -o "$SIM_OUT" *.v

echo "Compile OK"
echo

# ============================================================
# RUN DATASET
# ============================================================

total_run=0
total_skip=0

for label in {0..9}; do
    mem_dir="${MEM_ROOT}/mnist_img_${label}"
    out_dir="${CSV_ROOT}/label${label}"

    mkdir -p "$out_dir"

    echo "============================================"
    echo "Running BLOCK3 dump for label ${label}"
    echo "MEM DIR : ${mem_dir}"
    echo "OUT DIR : ${out_dir}"
    echo "============================================"

    for n in {0..99}; do
        img_idx=$((label * 100 + n))

        mem_file="${mem_dir}/img_${img_idx}.mem"

        conv3_out="${out_dir}/img_${img_idx}_conv3.csv"
        pool3_out="${out_dir}/img_${img_idx}_pool3.csv"

        if [[ ! -f "$mem_file" ]]; then
            echo "[SKIP] File not found: $mem_file"
            total_skip=$((total_skip + 1))
            continue
        fi

        echo "[RUN] label=${label}, file=${mem_file}"

        vvp "$SIM_OUT" \
            +MEM="$mem_file" \
            +CONV3_OUT="$conv3_out" \
            +POOL3_OUT="$pool3_out"

        total_run=$((total_run + 1))
    done

    echo
done

# ============================================================
# SUMMARY
# ============================================================

echo "============================================"
echo "DONE BLOCK3 DATASET DUMP"
echo "Total run  : ${total_run}"
echo "Total skip : ${total_skip}"
echo "============================================"