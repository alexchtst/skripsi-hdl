#!/bin/bash

set -euo pipefail

SIM_OUT="sim_fc.out"
TOP_MODULE="tb_fc_dump"

MEM_ROOT="mem"
CSV_ROOT="csv-results"

echo "============================================"
echo "Compiling FC testbench..."
echo "Top module : ${TOP_MODULE}"
echo "Output     : ${SIM_OUT}"
echo "============================================"

iverilog -g2012 -s "$TOP_MODULE" -o "$SIM_OUT" *.v

echo "Compile OK"
echo

total_run=0
total_skip=0

for label in {0..9}; do
    mem_dir="${MEM_ROOT}/mnist_img_${label}"
    out_dir="${CSV_ROOT}/label${label}"

    mkdir -p "$out_dir"

    echo "============================================"
    echo "Running FC dump for label ${label}"
    echo "MEM DIR : ${mem_dir}"
    echo "OUT DIR : ${out_dir}"
    echo "============================================"

    for n in {0..99}; do
        img_idx=$((label * 100 + n))

        mem_file="${mem_dir}/img_${img_idx}.mem"

        fc1_out="${out_dir}/img_${img_idx}_fc1.csv"
        fc2_out="${out_dir}/img_${img_idx}_fc2.csv"

        if [[ ! -f "$mem_file" ]]; then
            echo "[SKIP] File not found: $mem_file"
            total_skip=$((total_skip + 1))
            continue
        fi

        echo "[RUN] label=${label}, file=${mem_file}"

        vvp "$SIM_OUT" \
            +MEM="$mem_file" \
            +FC1_OUT="$fc1_out" \
            +FC2_OUT="$fc2_out"

        total_run=$((total_run + 1))
    done

    echo
done

echo "============================================"
echo "DONE FC DATASET DUMP"
echo "Total run  : ${total_run}"
echo "Total skip : ${total_skip}"
echo "============================================"
