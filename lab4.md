# CS 152 Laboratory Exercise 4
**Professor**: Christopher Fletcher  
**Department of Electrical Engineering & Computer Sciences**  
**University of California, Berkeley**  
**March 23, 2025**

## Revision History

| Revision | Date | Author(s) | Description |
|----------|------|-----------|-------------|
| 1.0 | 2022-04-08 | hngenc | Initial release |
| 1.1 | 2023-04-01 | Prashanth Ganesh | sp23 update |
| 1.2 | 2024-03-28 | Joshua You | sp24 update |
| 1.3 | 2025-03-19 | Ronit Nagarapu | sp25 update |

## 1 Introduction and Goals

In this lab, you will write RISC-V vector assembly code to gain a better understanding of how data-parallel code maps to vector-style processors, and to practice optimizing vector code for a given implementation.

While students are encouraged to discuss solutions to the lab assignments with each other, you must complete the directed portion of the lab yourself and submit your own work for these problems.

### 1.1 Graded Items

For Lab 4, the only required submission is your code for the **directed** portion. You only need to complete **2 of the 4 problems** for the directed portion. All code is to be submitted through **Gradescope**. Please follow Section 3.9 for instructions on how to submit your code to the Gradescope autograder. The open-ended portion is **optional**, and will not be graded.

- (Directed) Problem 3.5: `cmplxmult` code
- (Directed) Problem 3.6: `dgemv` code
- (Directed) Problem 3.7: `dgemm` code
- (Directed) Problem 3.8: `imax` code
- (Open-ended) Problem 4.1: `spmv` code
- (Open-ended) Problem 4.2: `rsort` code

## 2 Background

The RISC-V vector ISA programming model is best explained by contrast with other, popular data-parallel programming models. As a running example, we use a conditionalized SAXPY kernel, `CSAXPY`. Listings 1 and 2 show CSAXPY expressed in C as both a vectorizable loop and as a SPMD (single-program multiple-data) kernel. CSAXPY takes as input an array of boolean conditions, a scalar `a`, and vectors `x` and `y`; it computes `y += ax` for the elements for which the condition is true.

**Listing 1**: CSAXPY vectorizable loop
```c
void csaxpy(size_t n, bool cond[], float a, float x[], float y[])
{
    for (size_t i = 0; i < n; i++)
        if (cond[i])
            y[i] = (a * x[i]) + y[i];
}
```

**Listing 2**: CSAXPY SPMD kernel with 1-D thread launch
```c
csaxpy_spmd<<<((n-1)/32+1)*32>>>;

void csaxpy_spmd(size_t n, bool cond[], float a, float x[], float y[])
{
    if (tid.x < n)
        if (cond[tid.x])
            y[tid.x] = (a * x[tid.x]) + y[tid.x];
}
```

### 2.1 Packed-SIMD Programming Model

**Listing 3**: CSAXPY mapped to packed SIMD assembly with predication

*In all pseudo-assembly examples presented in this section, register `a0` holds variable `n`, `a1` holds pointer `cond`, `fa0` holds scalar `a`, `a2` holds pointer `x`, and `a3` holds pointer `y`.*

```assembly
csaxpy_simd:
    slli a0, a0, 2
    add a0, a0, a3
    vsplat4 vv0, fa0
stripmine_loop:
    vlb4 vv1, (a1)
    vcmpez4 vp0, vv1
    !vp0 vlw4 vv1, (a2)
    !vp0 vlw4 vv2, (a3)
    !vp0 vfmadd4 vv1, vv0, vv1, vv2
    !vp0 vsw4 vv1, (a3)
    addi a1, a1, 4
    addi a2, a2, 16
    addi a3, a3, 16
    bltu a2, a0, stripmine_loop
    # handle fringe cases when (n % 4) != 0
    # ...
    ret
```

register. Finally, the address registers are incremented by the SIMD width (lines 13-14), and the stripmine loop is repeated until the computation is finished (line 15) - almost. Since the stripmine loop handles four elements at a time, extra code is needed to handle up to three **fringe** elements at the end. For brevity, we omitted this code; in this case, it suffices to duplicate the loop body, predicating all of the instructions on whether their index is less than `n`.

**Listing 4**: CSAXPY mapped to packed SIMD assembly without predication

*The `vblend4 d,m,s,t` instruction implements a select function: `d = m ? s : t`*

```assembly
csaxpy_simd:
    slli a0, a0, 2
    add a0, a0, a3
    vsplat4 vv0, fa0
stripmine_loop:
    vlb4 vv1, (a1)
    vcmpez4 vv3, vv1
    vlw4 vv1, (a2)
    vlw4 vv2, (a3)
    vfmadd4 vv1, vv0, vv1, vv2
    vblend4 vv1, vv3, vv1, vv2
    vsw4 vv1, (a3)
    addi a1, a1, 4
    addi a2, a2, 16
    addi a3, a3, 16
    bltu a2, a0, stripmine_loop
    # handle fringe cases when (n % 4) != 0
    # ...
    ret
```

registers fails to execute on older machines with narrower ones.

### 2.2 SIMT Programming Model

**Listing 5**: CSAXPY mapped to SIMT assembly
```assembly
csaxpy_simt:
    mv t0, tid
    bgeu t0, a0, skip
    add t1, a1, t0
    lbu t1, (t1)
    beqz t1, skip
    slli t0, t0, 2
    add a2, a2, t0
    add a3, a3, t0
    flw ft0, (a2)
    flw ft1, (a3)
    fmadd.s ft0, fa0, ft0, ft1
    fsw ft0, (a3)
skip:
    stop
```

Listing 5 shows the same code mapped to a hypothetical SIMT architecture, akin to an NVIDIA GPU. The SIMT architecture exposes the data-parallel execution resources as multiple threads of execution; each thread executes one element of the vector. The microarchitecture fetches an instruction once but then executes it on many threads simultaneously using parallel datapaths; therefore, a scalar instruction shown in the code executes like a vector instruction.

One inefficiency of this approach is immediately evident: Since the number of launched threads must be a multiple of the warp size (32 for NVIDIA GPUs), the first action taken by each thread is to determine whether it is within bounds (lines 2-3). Another inefficiency results from the duplication of scalar computation: Despite the unit-stride access pattern, each thread explicitly computes its own addresses. (The SIMD architecture, in contrast, amortizes this work over the SIMD width.) Memory coalescing logic is then needed to recover the original unit-stride access pattern from the individual memory requests issued by each thread, which otherwise must be treated as a scatter/gather. Moreover, massive replication of scalar operands reduces the effective utilization of register file resources: Each thread has its own copy of the three array base addresses and the scalar `a`. This represents a threefold increase over the fundamental architectural state.

### 2.3 Traditional Vector Programming Model

**Listing 6**: CSAXPY mapped to traditional vector assembly
```assembly
csaxpy_tvec:
stripmine_loop:
    vsetvl t0, a0
    vlb vv0, (a1)
    vcmpez vp0, vv0
    !vp0 vlw vv0, (a2)
    !vp0 vlw vv1, (a3)
    !vp0 vfmadd.s vv0, vv0, fa0, vv1
    !vp0 vsw vv0, (a3)
    add a1, a1, t0
    slli t1, t0, 2
    add a2, a2, t1
    add a3, a3, t1
    sub a0, a0, t0
    bnez a0, stripmine_loop
    ret
```

The key feature of this architecture is the **vector length register** (VLR), which represents the number of vector elements that will be processed by each vector instruction, up to the hardware vector length (HVL). Software manipulates the VLR by requesting a certain application vector length (AVL) with the `vsetvl` instruction; in response, the vector unit sets the active vector length to the shorter of the AVL and the HVL.

As with packed SIMD architectures, a stripmine loop iterates until the application vector has been completely processed. But, as Listing 6 shows, the difference lies in the adjustment of the VLR at the head of every loop iteration (line 3). Most importantly, the software is agnostic to the underlying hardware vector length: The same code executes correctly and with maximal efficiency on machines with any HVL. Secondly, no fringe code is required at all: On the final trip through the loop, the VLR is simply set to the exact remainder.

The advantages of traditional vector architectures over the SIMT approach are owed to the coupled scalar control processor. The scalar register file holds only one copy of the array pointers and the scalar `a`. The address computation instructions execute only once per stripmine loop iteration, rather than once per element, effectively amortizing their cost by a factor of the HVL.

### 2.4 RISC-V Vector Programming Model

**Listing 7**: CSAXPY mapped to RISC-V V assembly
```assembly
csaxpy_rvv:
stripmine_loop:
    vsetvli t0, a0, e8, m2, ta, ma  # set VL; configure SEW=8 LMUL=2
    vle8.v v8, (a1)                 # load cond[i]
```

The RISC-V V vector extension (RVV) resembles a traditional vector ISA, with some key distinctions. In particular, the organization of the vector register file is dynamically configurable through the **vector type register** (`vtype`), which consists of two fields: SEW and LMUL. These dictate how the vector state is conceptually partitioned along two orthogonal dimensions.

The **standard element width** (SEW) sets the default width of each vector element in bits. A narrower SEW enables elements to be more densely packed into the available storage, increasing the maximum vector length. SEW also determines the operation widths of **polymorphic** vector instructions, which allow reusing the same instruction to support a variety of data widths (e.g., both single-precision and double-precision floating-point), thereby conserving valuable opcode space.

The **length multiplier** (LMUL) is an integer power of 2 (from 1 to 8) that controls how many consecutive vector registers are grouped together to form longer vectors. With LMUL=2, vector registers `vn` and `vn+1` are operated on as one vector with twice the maximum vector length. Instructions must use vector register specifiers evenly divisible by LMUL; attempts to invalid specifiers raise an illegal instruction exception. LMUL serves to increase efficiency through longer vectors when fewer architectural registers are needed, as well as to accommodate mixed-width operations (as a mechanism to maintain identical vector lengths among vectors of different datatype widths).

Listing 7 shows CSAPY mapped to RVV 0.10. The `vsetvli` instruction enables both the vector length and `vtype` to be configured in one step. SEW is initially set to 8 bits (line 3) to load the boolean values from `cond`. The second `vsetvli` instruction (line 6) widens SEW to 32 for single-precision operations; the special use of `x0` for the requested vector length has the effect of retaining the current vector length.

```assembly
csaxpy_rvv:
stripmine_loop:
    vsetvli t0, a0, e8, m2, ta, ma  # set VL; configure SEW=8 LMUL=2
    vle8.v v8, (a1)                 # load cond[i]
    vmsne.vi v0, v8, 0              # set mask if cond[i] != 0
    vsetvli x0, x0, e32, m8, ta, mu  # configure SEW=32 LMUL=8; retain VL
    vle32.v v8, (a2)                 # load x[i]
    vle32.v v16, (a3)                # load y[i]
    vfmacc.vf v16, fa0, v8, v0.t      # y[i] = (a * x[i]) + y[i] if cond[i] != 0
    vse32.v v16, (a3)                 # store y[i]
    sub a0, a0, t0                    # decrement n
    add a1, a1, t0                    # bump pointer cond
    slli t0, t0, 2                    # scale VL to byte offset
    add a2, a2, t0                    # bump pointer x
    add a3, a3, t0                    # bump pointer y
    bnez a0, stripmine_loop
    ret
```

There are no separate vector predicate registers in RVV, which reduces the minimum architectural state. In the base V extension, predicated instructions always use `v0` as the source of the vector mask, while other vector registers can be used to temporarily hold mask values computed with vector logical and comparison instructions. Annotating a maskable instruction with `v0.t` (line 9) causes the operation to be executed conditionally based on the least-significant bit of the mask element in `v0`.

In the example, note that the vector mask is computed under SEW=8 but consumed under SEW=32. For the predicate bit of each element to remain in the same positions under both `vtype` settings, the SEW/LMUL ratio must be kept constant. (The "Mask Register Layout" section explains the constraints involved.) Hence, it is necessary to set LMUL=2 when SEW=8 to match the use of LMUL=8 later.

### 2.4.1 Specification Versioning

Be sure to use the correct version of the RVV specification for this lab.

The V extension has evolved substantially over the past few years. Both this lab and the lecture use the 0.10 draft of the specification, archived at https://inst.eecs.berkeley.edu/~cs152/sp22/handouts/sp22/riscv-v-spec-0.10.html.

The latest working draft is available at https://github.com/riscv/riscv-v-spec. In particular, the vector extension was officially ratified in November 2021, and the first commercial processors implementing it have become available since then. Older iterations of Lab 4 were built on the 0.4 specification, from which the current proposal diverges radically enough that they should be regarded as two different ISAs.

Here are some of the important sections to look at in the RVV specification:

1. Vector Loads and Stores (Section 7)
2. Vector Floating-Point Instructions (Section 14)
3. Vector Reduction Operations (Section 15)
4. Vector Mask Instructions (Section 16)
5. Vector Permutation Instructions (Section 17)

Please read the above sections before attempting the rest of the lab. Programming the kernels will be difficult without understanding the vector instructions that are available for you to use.

## 3 Directed Portion (100%)

This lab focuses on writing programs that target the RISC-V vector ISA. This will involve:

1. Writing vector assembly code for different benchmarks
2. Testing their correctness and estimating performance using the RISC-V ISA simulator, `spike`

Although normally just a functional simulator, to create a more interesting lab, `spike` has been extended with a rudimentary timing model of a single-issue in-order core with a standard vector unit. This timing model approximates instruction latencies from data and structural hazards, multi-cycle functional units, cache misses, and branch mispredictions.

For these simulations, `spike` is configured to model the following hardware parameters, intended to closely match the default Ro cketCon g design from Chipyard.

Vector unit:
- 512-bit hardware vector length (VLEN), 128-bit datapath
- Two vector functional units (VFU0, VFU1)
  - Both VFUs contain an integer ALU, an integer multiplier, and floating-point FMA units
  - VFU0 handles reductions
  - VFU1 handles floating-point conversions and comparisons
- One vector memory unit (VMU)
  - 128-bit interface to L1 data cache
  - 128 bits/cycle bandwidth for unit-stride memory operations
  - 1 element/cycle bandwidth for constant-stride and indexed memory operations (including vector AMOs)
- In-order issue with flexible vector chaining

Functional units:
- Integer ALU, 1-cycle latency
- Unpipelined scalar integer multiplier (8 bits/cycle) and divider (1 bit/cycle)
- Pipelined vector integer multiplier, 3-cycle latency
- Pipelined scalar and vector floating-point units
  - 4-cycle double-precision FMA latency
  - 3-cycle single-precision and half-precision FMA latency
  - 2-cycle floating-point conversion and comparison latency
- Unpipelined vector reduction unit, 1 element/cycle

Memory hierarchy:
- L1 instruction cache: 16 KiB, 4-way, 64 B lines
- Blocking L1 data cache: 16 KiB, 4-way, 64 B lines, 2-cycle latency for scalar loads
- Inclusive L2 cache: 512 KiB, 8-way, 64 B lines, 20-cycle latency
- 75-cycle main memory latency

Branch prediction:
- 3-cycle branch misprediction penalty
- 28-entry fully-associative BTB
- 512-entry BHT, gshare with 8 bits of global history
- 6-entry RAS

### 3.1 Setup

To complete this lab, `ssh` into an instructional server with the instructional computing account provided to you. The lab infrastructure has been set up to run on the `eda{1..3}.eecs.berkeley.edu` machines (`eda-1.eecs`, `eda-2.eecs`, etc.).

Once logged in, source the following script to initialize your shell environment so as to be able to access to the tools for this lab.

```bash
source ~cs152/sp25/cs152.lab4.bashrc
```

First, clone the lab materials into an appropriate workspace and initialize the submodules.

```bash
git clone https://github.com/ucb-bar/chipyard-cs152-sp24.git -b cs152-lab4-sp25 lab4
cd lab4
LAB4ROOT="$(pwd)"
```

This document henceforth uses `${LAB4ROOT}` to denote the path of the `lab4` working tree.

### 3.2 Register Convention

When writing assembly code, strictly adhere to the integer and floating-point register conventions set forth by the RISC-V psABI (processor-specific application binary interface). Inadvertently clobbering registers will cause compatibility issues when linked with compiled code.

The `x` registers `s0`-`s11` are callee-saved, which should be preserved across function calls by saving on the stack and restoring them if used.

`t0`-`t6` and `a0`-`a7` can be used as temp oraries.

`gp` and `tp` are reserved for special purposes in the execution environment and should be avoided. Similarly for the `f` registers, `fs0`-`fs11` are callee-saved.

`ft0`-`ft11` and `fa0`-`fa7` can be used as temp oraries.

Currently, all vector registers `v0`-`v31` are treated as caller-saved.

### 3.3 Conditional SAXPY (`csaxpy`)

This first kernel is intended to provide you with an idea of how to design a kernel using the RISC-V Vector ISA.

The full vector code for `csaxpy` is already provided to you in `${LAB4ROOT}/benchmarks/vec-csaxpy/vec_csaxpy.S`. It is essentially identical to the example described earlier in Section 2.4.

Take a moment to study how it works; although relatively simple, it is a useful demonstration of some important ISA features such as SEW, LMUL, and predication.

For comparison, the scalar version is also available in `${LAB4ROOT}/benchmarks/csaxpy`.

Build and run both benchmarks on `spike` as follows:

```bash
cd ${LAB4ROOT}/benchmarks
make csaxpy.riscv.out
make vec-csaxpy.riscv.out
```

Now that you understand the infrastructure, how to run benchmarks, and how to collect results, you can begin writing your own benchmarks.

### 3.4 Directed Portion Vector Kernels

For the directed portion submission, pick 2 of the 4 kernels below to implement. Once done, follow the directions in Section 3.9 to submit your code to the Gradescope assignment.

- (Directed) Problem 3.5: `cmplxmult` code
- (Directed) Problem 3.6: `dgemv` code
- (Directed) Problem 3.7: `dgemm` code
- (Directed) Problem 3.8: `imax` code

### 3.5 Complex Vector Multiplication (`cmplxmult`)

`cmplxmult` multiplies two vectors of single-precision complex values. The psuedo code is shown in Listing 8.

Listing 8: `cmplxmult` pseudo code
```c
struct Complex {
    float real;
    float imag;
};

for (i = 0; i < m; i++) {
    c[i].real = (a[i].real * b[i].real) - (a[i].imag * b[i].imag);
    c[i].imag = (a[i].imag * b[i].real) + (a[i].real * b[i].imag);
}
```

Build and run the scalar version provided in `${LAB4ROOT}/benchmarks/cmplxmult/`:

```bash
make cmplxmult.riscv.out
```

Your task is to vectorize the code. Complete the assembly function in `${LAB4ROOT}/benchmarks/vec-cmplxmult/vec_cmplxmult.S` according to the TODO comments.

When you are ready to test your code, build and run it on the ISA simulator:

```bash
make vec-cmplxmult.riscv.out
```

If no errors are reported, you are done!

Refer to Appendix A for debugging tips.

#### 3.5.1 Segmented Vector Memory Operations

When working with arrays of structs, you may want to use `segmented` vector memory operations to conveniently unpack each field into separate (consecutively numbered) vector registers. These are described in the "Vector Load/Store Segment Instructions" section of the RVV spec.

#### 3.5.2 Fused Multiply-Add Operations

Although not necessary, more efficient code can be written by using fused multiply-add instructions that issue two vector floating-point operations for each instruction. These come in two destructive forms that overwrite one of the vector register operands, either the addend or the first multiplicand.

All relevant fused varieties are listed in the "Vector Single-Width Floating-Point Fused Multiply-Add Instructions" section.

### 3.6 Double-Precision Generalized Matrix-Vector Multiplication (`dgemv`)

`dgemv` performs double-precision matrix-vector multiplication `y = Ax + y`, where `x` and `y` are vectors and `A` is an `m` x `n` matrix. It is a fundamental kernel part of B LAS (Basic Linear Algebra Subprograms) Level 2. Since the arithmetic intensity is relatively low (each element of `A` is used only once), its performance is typically memory-bound.

The unoptimized pseudo code is shown in Listing 9. The matrix `A` is stored in row-major order, i.e., the entries in a row are contiguous in memory.

Listing 9: Unoptimized `dgemv` pseudo code
```c
for (i = 0; i < m; i++) {
    for (j = 0; j < n; j++) {
        y[i] += A[i][j] * x[j];
    }
}
```

Build and run the scalar version provided in `${LAB4ROOT}/benchmarks/dgemv/`:

```bash
make dgemv.riscv.out
```

Your task is to vectorize the inner loop along the `n` dimension.

Complete the assembly function in `${LAB4ROOT}/benchmarks/vec-dgemv/vec_dgemv.S` according to the TODO comments. When you are ready to test your code, build and run it on the ISA simulator:

```bash
make vec-dgemv.riscv.out
```

#### 3.6.1 Reductions and Scalars

Note that the inner product to compute `y[i]` involves a sum reduction. For long vectors particularly, reduction operations can be somewhat expensive due to the inter-element communication required. Thus, the recommended approach is to stripmine the loop to accumulate the partial sums in parallel, and then reduce the vector at the end of the loop to yield a single value.

You may find the "Vector Single-Width Floating-Point Reduction Instructions" section of the RVV spec to be useful.

Note that the vector reduction instructions interact with scalar values held in vector registers: The scalar result is written to element 0 of the destination vector register, and the operation also takes an initial scalar input from element 0 of a second vector operand. Refer to "Floating-Point Scalar Move Instructions" for transferring a single value between an `f` register and a vector register.

### 3.7 Double-Precision Generalized Matrix-Matrix Multiplication (`dgemm`)

`dgemm` performs double-precision matrix-matrix multiplication `C = AB + C`, where `A` and `B` are both `n` x `n` matrices. This is another fundamental kernel for scientific computing and machine learning, part of BLAS Level 3. The unoptimized pseudo code is shown in Listing 10. All matrices are stored in row-major order.

Listing 10: Unoptimized `dgemm` pseudo code
```c
for (i = 0; i < n; i++) {
    for (j = 0; j < n; j++) {
        for (k = 0; k < n; k++) {
            C[i][j] += A[i][k] * B[k][j];
        }
    }
}
```

The optimized scalar version is provided in `${LAB4ROOT}/benchmarks/dgemm/`. Note how loop unrolling (of `i` and `k`) and register blocking expose opportunities for data reuse to improve efficiency. Some extra code is needed to handle the remainder after the unrolled loop. For simplicity, this implementation is not cache-blocked, although doing so would be a straightforward transformation. Build and run the scalar code as follows:

```bash
make dgemm.riscv.out
```

Your task is to vectorize the second loop over `j`. Submatrices of `C` and `B` can be held in vector registers, while the entries of `A` are loaded as scalars. This naturally leads to using vector-scalar operations to compute the partial products. As a hint, first work through the matrix multiplication by hand to see how the computation can be rearranged into a vectorizable pattern.

Complete the assembly functions for the main inner loop in `${LAB4ROOT}/benchmarks/vec-dgemm/vec_dgemm_inner.S` and the remainder loop in `${LAB4ROOT}/benchmarks/vec-dgemm/vec_dgemm_remainder.S`. Try to leverage fused multiply-add instructions where possible. When you are ready to test your code, build and run it on the ISA simulator:

```bash
make vec-dgemm.riscv.out
```

#### 3.7.1 Fused Multiply-Add Operations

You may find the "Vector Single-Width Floating-Point Fused Multiply-Add Instructions" section of the RVV spec to be useful.

### 3.8 Index of Maximum Element (`imax`)

In this problem, you will vectorize a less conventional vector application, `imax`, which finds the index of the largest value in an array. One use case is for identifying the pivot element in certain matrix algorithms, such as Gaussian elimination. The pseudo code is shown in Listing 11.

Listing 11: `imax` pseudo code
```c
idx = 0, max = -INFINITY;
for (i = 0; i < n; i++) {
    if (x[i] > max) {
        max = x[i];
        idx = i;
    }
}
```

Build and run the scalar version provided in `${LAB4ROOT}/benchmarks/imax/`:

```bash
make imax.riscv.out
```

Despite the simplicity of the scalar implementation, vectorizing `imax` is not as trivial. The following approach is suggested:

1. Keep the current maximum in an `f` register, initialized to negative infinity, and the current index in an `x` register, initialized to zero.
2. Load a vector and find its maximum with a reduction.
3. Compare against the global maximum.
4. Use a vector floating-point comparison to represent the location of the maximum element as a vector mask.
5. Find the first set bit in the mask using `vfirst.m`. This yields the index of the lowest-numbered element of the mask vector that has its least-significant bit set, or -1 otherwise.
6. Update the global index and maximum if necessary.

Once you understand how the reduction and mask operations work, complete the assembly function in `${LAB4ROOT}/benchmarks/vec-imax/vec_imax.S` according to the TODO comments. When you are ready to test your code, build and run it on the ISA simulator:

```bash
make vec-imax.riscv.out
```

#### 3.8.1 Reduction Operations

You may find the "Vector Single-Width Floating-Point Reduction Instructions" section of the RVV spec to be useful.

### 3.9 Submission

Run the following to collect all of your code for the directed portion into one archive, and upload `directed.zip` to the Gradescope autograder.

```bash
make zip-directed
```

The following source files should be present at the root of the ZIP file:

- vec_cmplxmult.S
- vec_dgemv.S
- vec_dgemm_inner.S
- vec_dgemm_remainder.S
- vec_imax.S

The directed problems are evaluated based on correctness, so please check that your code passes the autograder test suite. Note, you only have to complete 2 of the 4 kernels.

No written report is required for the directed portion.

## 4 Open-Ended Portion (0%) - Optional

Select one of the following questions per team.

In writing your optimized implementation and describing your methodology in the report, the goal is to demonstrate your understanding of vector architectures, the sources of their performance advantages, and how these qualities can be employed in important computational kernels.

### 4.1 Sparse Matrix-Vector Multiplication (`spmv`)

For this problem, you will implement and optimize RISC-V vector code for sparse matrix-vector multiplication (SpMV), which is extensively used for graph processing and machine learning. SpMV computes `y = Ax`, where `A` is a sparse matrix and `x` is a dense vector.

Unlike other dense linear algebra algorithms, most entries of `A` are zero, and the matrix is represented in a condensed format in memory. The unoptimized pseudo code is shown in Listing 12.

Listing 12: `spmv` pseudo code
```c
for (i = 0; i < n; i++) {
    for (k = ptr[i]; k < ptr[i+1]; k++) {
        y[i] += A[k] * x[idx[k]];
    }
}
```

A scalar reference implementation is provided in `${LAB4ROOT}/benchmarks/spmv`. Build and run the benchmark as follows:

```bash
make spmv.riscv.out
```

Add your own double-precision vector implementation to `${LAB4ROOT}/benchmarks/vec-spmv/vec_spmv.S`. When you are ready to test your code, build and run it on the ISA simulator:

```bash
make vec-spmv.riscv.out
```

#### 4.1.1 Optimization

Once your code is correct, do your best to optimize `spmv` to minimize the number of cycles (per `mcycle`).

You are only allowed to write code in `vec_spmv.S`; do not change any code in `vec_spmv_main.c` except for debugging. If you would like to perform some transformation on the inputs, only do so after you have verified the non-transformed version.

Common techniques that generally work well are loop unrolling, loop interchange, lifting loads out of inner loops and scheduling them earlier, blocking the code to utilize the full register file, and transposing matrices to achieve unit-stride accesses for improved locality.

More specifically to vector architectures, try to refactor all element loads into vector loads. Use fused multiply-add instructions where possible. Also, carefully choose which loop(s) to vectorize for this problem, as not all loops can be safely vectorized!

#### 4.1.2 Submission

Please ensure that your code is appropriately commented. Use the following command to archive your code for submission, and record the resulting `vec-spmv.zip` file to the Gradescope autograder.

```bash
make zip-spmv
```

In a separate report, roughly explain how your SpMV implementation works, and report the dynamic instruction count and cache statistics. Also explain how you arrived at your implementation, and describe at least three optimizations that you applied in detail. How much improvement did they yield over the previous iterations of your code?

### 4.2 Radix Sort (`rsort`)

For this problem, you will implement and optimize RISC-V vector code for radix sort (`rsort`), a non-comparative integer sorting algorithm. The unoptimized pseudo code is shown in Listing 13. In iteration `i`, each value is assigned to a bucket by its `i`-th digit, starting from the least-significant digit. After all values are allocated to buckets, they are merged sequentially into a new list. This algorithm repeats until all digits in every value have been traversed.

Listing 13: `rsort` pseudo code
```c
// TYPE_MAX: maximum value of the data type
for (power = 1; power < TYPE_MAX; power *= BASE) {
    // Number of buckets = BASE
    for (k = 0; k < BASE; k++) {
        buckets[k] = [];
    }
    for (j = 0; j < ARRAY_SIZE(array); j++) {
        key = array[j];
        // Extract next digit
        digit = (key / power) % BASE;
        // Assign value to bucket
        buckets[digit].append(key);
    }
    // Merge buckets sequentially
    new_array = [];
    for (k = 0; k < BASE; k++) {
        new_array.extend(bucket[k]);
    }
    array = new_array;
}
```

A scalar reference implementation is provided in `${LAB4ROOT}/benchmarks/rsort`. Rather than directly assigning the values to buckets, the optimized version uses the buckets to produce a histogram of occurrences of each digit, which is then used to compute the offset of each element in the new array. Thus, the merge step becomes a permutation. Build and run the benchmark as follows:

```bash
make rsort.riscv.out
```

Add your own vector implementation to `${LAB4ROOT}/benchmarks/vec-rsort/vec_rsort.S`. The data values are 32-bit unsigned ints. When you are ready to test your code, build and run it on the ISA simulator:

```bash
make vec-rsort.riscv.out
```

#### 4.2.1 Optimization

You can feel that this may be a more challenging algorithm to vectorize than usual, so focus on first getting the code to work correctly before embarking on any complicated optimizations.

Once your code passes the given test, do your best to optimize `rsort` to minimize the number of cycles (per `mcycle`). You are only allowed to write code in `vec_rsort.S`; do not change any code in `vec_rsort_main.c` except for debugging.

Indexed vector memory operations (scatter/gatter) and predication will be heavily used in this benchmark. Take care when updating buckets, as the same bucket may be accessed multiple times by a vector operation.

The general suggestions for `spmv` in Problem 4.1 also apply to `rsort`. In practice, `vrem` can be expensive in terms of performance, being essentially a long-latency divide operation per element, so it should be avoided. You may also notice that every bucket might be able to fit in a single vector; if so, consider how buckets could be kept in the same vectors across iterations.

#### 4.2.2 Submission

Please ensure that your code is appropriately commented. Use the following command to archive your code for submission, and upload the resulting `vec-rsort.zip` file to the Gradescope autograder.

```bash
make zip-rsort
```

In a separate report, roughly explain how your `rsort` implementation works, and record the dynamic instruction count and cache statistics. Also explain how you arrived at your implementation, and describe at least three optimizations that you applied in detail. How much improvement did they yield over the previous iterations of your code?

## 5 Acknowledgments

This lab was originally designed by Donggyu Kim in spring 2018. It is heavily inspired by the previous sets of CS 152 labs developed by Christopher Celio, which targeted the Hwacha vector processor [2].

References

[1] R. M. Russell, "The CRAY-1 computer system," Communications of the ACM, vol. 21, no. 1, pp. 63-72, Jan. 1978.
doi: 10.1145/359327.359336.

[2] Y. Lee, "Decoupled vector-fetch architecture with a scalarizing compiler," Ph.D. dissertation, EECS Department, University of California, Berkeley, May 2016. [Online]. Available: http://www2.eecs.berkeley.edu/Pubs/TechRpts/2016/EECS-2016-117.html.

## A Appendix: Debugging

For each benchmark, the ISA simulator prints an instruction trace to `${LAB4ROOT}/benchmarks/ *.riscv.out`.

The disassembly for specific benchmarks can be dumped as follows, which can be useful for comparing against the instruction traces and verifying that the code was assembled as expected.

```bash
cd ${LAB4ROOT}/benchmarks
make <bmark>.riscv.dump
```

It is also possible to generate a more detailed commit log that records every value written to each destination register and the address stream of memory accesses.

```bash
make <bmark>.riscv.log
```

The current SEW, LMUL, and vector length are also logged for each vector instruction.

Note that the contents of a vector register are shown concatenated as a single raw hex value; refer to the "Mapping of Vector Elements to Vector Register State" section in the RVV spec for how to unpack the layout. For `LMUL` > 1, the `v` registers that comprise a vector register group are displayed separately, possibly in an arbitrary order.

Finally, it can be very helpful to debug using a smaller dataset. Switch to `dataset2.h` for the open-ended problems, or generate custom input data using the provided scripts. However, make sure that your code eventually passes the test using `dataset1.h`.

