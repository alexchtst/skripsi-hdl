#!/bin/bash

set -euo pipefail

# ============================================================
# CONFIG
# ============================================================

SIM_OUT="sim.out"

SRC_FILES=(
  tb_block1_dump.v
  stream_safe_28x28_mem_reader.v
  block1.v
  block1_channel_unit.v
  block1_weight_rom.v
  block1_kernel_mac_unit.v
  block1_fifo_shift_register_kernel.v
  block1_fifo_shift_register_pool.v
)

MEM_ROOT="mem"
CSV_ROOT="csv-results"

# ============================================================
# COMPILE
# ============================================================

echo "============================================"
echo "Compiling Verilog..."
echo "============================================"

iverilog -g2012 -o "$SIM_OUT" "${SRC_FILES[@]}"

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
    echo "Running label ${label}"
    echo "MEM DIR : ${mem_dir}"
    echo "OUT DIR : ${out_dir}"
    echo "============================================"

    for n in {0..99}; do
        img_idx=$((label * 100 + n))

        mem_file="${mem_dir}/img_${img_idx}.mem"

        conv_out="${out_dir}/img_${img_idx}_conv.csv"
        pool_out="${out_dir}/img_${img_idx}_pool.csv"

        if [[ ! -f "$mem_file" ]]; then
            echo "[SKIP] File not found: $mem_file"
            total_skip=$((total_skip + 1))
            continue
        fi

        echo "[RUN] label=${label}, file=${mem_file}"

        vvp "$SIM_OUT" \
            +MEM="$mem_file" \
            +CONV_OUT="$conv_out" \
            +POOL_OUT="$pool_out"

        total_run=$((total_run + 1))
    done

    echo
done

# ============================================================
# SUMMARY
# ============================================================

echo "============================================"
echo "DONE"
echo "Total run  : ${total_run}"
echo "Total skip : ${total_skip}"
echo "============================================"