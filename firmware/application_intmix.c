/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2025-2026 the FIawase authors
 *
 * application_intmix -- the FI campaign workload (tinyriscv / rv32im)
 *
 * An integer matrix multiply is the core, wrapped in two small helper
 * kernels that cover the functional units the matmul misses:
 *
 *   unit                        matmul?   covered by
 *   -------------------------   -------   ------------------------
 *   multiplier (mul)              yes
 *   ALU add/sub                   yes
 *   load / store                  yes
 *   address generation            yes
 *   regular loop branches         yes
 *   shifter sll/srl               no       xorshift32 + rotl32
 *   logic xor/and                 no       xorshift32 + folding
 *   data-dependent branches       no       insertion sort
 *   variable-length inner loop    no       the sort's while loop
 *
 * Output: one checksum line. Done flag: GPIO_DATA_OUT |= 0x1.
 *
 * Per round:
 *   A. fill an 8x8 matrix with xorshift32   ->   64 shift/xor/store
 *   B. fold A.At                            ->  512 multiply-accumulate
 *                                               + 1024 loads   (~40%)
 *   C. insertion sort 64 elements           -> ~1024 data-dependent
 *                                               moves          (~55%)
 *   D. weighted fold into a checksum, fed back as the next seed
 *
 * Measured at roughly 11,900 instructions per round, so about 190k
 * instructions at BENCH_ROUNDS=16.
 *
 * Optimisation barrier: rounds carry a loop-carried dependency (the
 * previous h decides this round's data) and the final h is printed, so
 * the compiler can neither hoist the body out nor fuse the rounds.
 *
 * Why this workload for fault injection: it has a long IO-free compute
 * window with a single observable output, so a flipped bit either changes
 * the checksum, hangs the program, or does nothing -- three outcomes that
 * are trivial to tell apart over the UART.
 */

/* The two build systems disagree on the "simulation" macro; normalise to
 * SIMULATION:
 *   - bsp.mk        : CFLAGS += -DSIMULATION
 *   - the chaos SDK : make SIMULATION=1 passes -DCFG_SIMULATION */
#if defined(CFG_SIMULATION) && !defined(SIMULATION)
#define SIMULATION 1
#endif

#include <stdint.h>

#include "sim_ctrl.h"
#include "uart.h"
#include "xprintf.h"
#include "pinmux.h"

#define GPIO_BASE        0x03000000
#define GPIO_IO_MODE     (*(volatile uint32_t*)(GPIO_BASE + 0x00))
#define GPIO_DATA_OUT    (*(volatile uint32_t*)(GPIO_BASE + 0x0C))
#define GPIO_MODE_OUTPUT 0b10

/* Number of rounds. Override with COMMON_FLAGS += -DBENCH_ROUNDS=n.
 * Drop to 2-4 if RTL simulation is too slow -- note that changing it
 * changes the checksum. */
#ifndef BENCH_ROUNDS
#define BENCH_ROUNDS 16u
#endif

/* Matrix edge length. Work grows as N^3 (N=8 -> 512 MACs, N=10 -> 1000).
 * Raise it to make the matmul dominate; .bss grows to N*N*4 bytes. */
#define MAT_N     8u
#define MAT_WORDS (MAT_N * MAT_N)   /* 64 words = 256 B, the only static buffer */

/* Elements to sort (<= MAT_WORDS). Sorting grows as N^2, matmul as N^3.
 * At 64 the sort is ~56% and the matmul ~37%; at 32 the sort drops to
 * ~22% and the matmul rises to ~61%. */
#ifndef SORT_N
#define SORT_N MAT_WORDS
#endif

static uint32_t mat[MAT_WORDS];

/* ------------------------------------------------------------ primitives */

static inline uint32_t rotl32(uint32_t x, uint32_t r)
{
    r &= 31u;                       /* shift count must be < 32, else undefined behaviour */
    return r ? ((x << r) | (x >> (32u - r))) : x;
}

/* xorshift32: 3 shifts + 3 xors, no multiply -- complements the matmul */
static inline uint32_t xorshift32(uint32_t s)
{
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    return s;
}

/* --------------------------------------------------------- A. build data */

static uint32_t fill_matrix(uint32_t seed)
{
    if (seed == 0u)                 /* xorshift's absorbing state, must be avoided */
        seed = 0x9E3779B9u;

    for (uint32_t i = 0; i < MAT_WORDS; i++) {
        seed = xorshift32(seed);
        mat[i] = seed;
    }
    return seed;
}

/* ------------------------------------------------- B. 8x8 integer matmul */

/* Compute A.At and fold the 64 results into one 32-bit value. Using the
 * transpose as the second operand means only one matrix is needed, which
 * halves the RAM. The inner loop is a tight lw + lw + mul + add, which is
 * exactly what saturates an rv32im multiplier. */
__attribute__((noinline))
static uint32_t matmul_fold(void)
{
    uint32_t sum = 0;

    for (uint32_t i = 0; i < MAT_N; i++) {
        for (uint32_t j = 0; j < MAT_N; j++) {
            uint32_t acc = 0;
            for (uint32_t k = 0; k < MAT_N; k++)
                acc += mat[i * MAT_N + k] * mat[j * MAT_N + k];
            sum ^= rotl32(acc, i + j);
        }
    }
    return sum;
}

/* ---------------------------------------------------- C. insertion sort */

/* Insertion sort rather than bubble sort: the inner loop is a while with a
 * data-dependent early exit, so branch direction is decided entirely by the
 * data -- the least pipeline-friendly case, and the most interesting one
 * to watch stall. */
__attribute__((noinline))
static void insertion_sort(uint32_t *a, uint32_t n)
{
    for (uint32_t i = 1; i < n; i++) {
        uint32_t key = a[i];
        uint32_t j = i;
        while (j > 0u && a[j - 1] > key) {   /* j > 0, not j >= 0: j is unsigned */
            a[j] = a[j - 1];
            j--;
        }
        a[j] = key;
    }
}

/* ----------------------------------------------------------- main loop */

static uint32_t bench_run(void)
{
    uint32_t seed = 0x1234ABCDu;
    uint32_t h    = 0x811C9DC5u;

    for (uint32_t r = 0; r < BENCH_ROUNDS; r++) {
        /* The point: the previous round's h seeds this round's data. This
         * loop-carried dependency stops the compiler hoisting the body out
         * of the loop or fusing the rounds together. */
        seed = fill_matrix(seed ^ h);

        h ^= matmul_fold();

        insertion_sort(mat, SORT_N);
        /* Consume the sorted order with a weighted fold: change the order and h
           changes, so the sort cannot be optimised away */
        for (uint32_t i = 0; i < MAT_WORDS; i++)
            h = h * 31u + mat[i];

        h = rotl32(h, r + 1u);
    }
    return h;
}

/* ---------------------------------------------------------------- main */

int main(void)
{
    uint32_t result;

    GPIO_IO_MODE  |= (GPIO_MODE_OUTPUT << 0);
    GPIO_DATA_OUT &= ~0x1;

#ifdef SIMULATION
    sim_ctrl_init();
#else
    uart_init(UART0, uart0_putc);
    pinmux_set_io0_func(IO0_UART0_TX);
    pinmux_set_io3_func(IO3_UART0_RX);
#endif

    /* ===== pure compute window: no IO at all in here ===== */
    result = bench_run();
    /* ===== end of the compute window ===== */

    xprintf("%08x\n", result);

    GPIO_DATA_OUT |= 0x1;       /* done flag */

    return 0;
}
