#!/bin/bash

set -euo pipefail

# ============================================================
# CONFIG
# ============================================================

SIM_OUT="sim2.out"
TOP_MODULE="tb_block2_dump"

MEM_ROOT="mem"
CSV_ROOT="csv-results"

# ============================================================
# COMPILE
# ============================================================

echo "============================================"
echo "Compiling Block2 testbench..."
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
    echo "Running BLOCK2 dump for label ${label}"
    echo "MEM DIR : ${mem_dir}"
    echo "OUT DIR : ${out_dir}"
    echo "============================================"

    for n in {0..99}; do
        img_idx=$((label * 100 + n))

        mem_file="${mem_dir}/img_${img_idx}.mem"

        conv2_out="${out_dir}/img_${img_idx}_conv2.csv"
        pool2_out="${out_dir}/img_${img_idx}_pool2.csv"

        if [[ ! -f "$mem_file" ]]; then
            echo "[SKIP] File not found: $mem_file"
            total_skip=$((total_skip + 1))
            continue
        fi

        echo "[RUN] label=${label}, file=${mem_file}"

        vvp "$SIM_OUT" \
            +MEM="$mem_file" \
            +CONV2_OUT="$conv2_out" \
            +POOL2_OUT="$pool2_out"

        total_run=$((total_run + 1))
    done

    echo
done

# ============================================================
# SUMMARY
# ============================================================

echo "============================================"
echo "DONE BLOCK2 DATASET DUMP"
echo "Total run  : ${total_run}"
echo "Total skip : ${total_skip}"
echo "============================================"