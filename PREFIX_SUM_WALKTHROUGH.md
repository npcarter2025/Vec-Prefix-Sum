# DETAILED WALKTHROUGH OF RISC-V VECTOR PREFIX SUM ALGORITHM

## C Code for Prefix Sum
```c
PSEUDOCODE:
uint8_t element[SIZE];
uint8_t sum[SIZE];
for (i = 0; i < SIZE; i++) {
    sum[i] = 0;
    for (j = 0; j <= i; j++) {
        sum[i] += element[j];
    }
}
```
Quick Explanation of algorithm:

We're going to use a small array for this example: 
InputArray: [3, 1, 4, 1, 5, 9]

| Index | Calculation | Result |
|-------|-------------|--------|
| 0 | 3 | 3 |
| 1 | 3 + 1 | 4 |
| 2 | 3 + 1 + 4 | 8 |
| 3 | 3 + 1 + 4 + 1 | 9 |
| 4 | 3 + 1 + 4 + 1 + 5 = 9 + 5 | 14 |
| 5 | 3 + 1 + 4 + 1 + 5 + 9 = 9 + 14 | 23 |

This produces the correct prefix sum array: [3, 4, 8, 9, 14, 23]

# HOW TO DO THIS WITH VECTORS:


## Key Formulas

### Vector Length Calculations
- **VLMAX (Maximum Vector Length)**: VLMAX = VLEN / SEW × LMUL
  - VLEN: Hardware vector register length in bits
  - SEW: Selected Element Width in bits
  - LMUL: Vector length multiplier (1, 2, 4, or 8)

- **VL (Actual Vector Length)**: VL = min(VLMAX, AVL)
  - AVL: Application Vector Length (requested elements to process)
  - VL is returned in the destination register of `vsetvli`

### VSETVLI Instruction
- Syntax: `vsetvli rd, rs1, vtypei`
  - rd: Destination register (receives VL value)
  - rs1: Source register (contains AVL value)
  - vtypei: Immediate value encoding vector configuration

- When executing `vsetvli t0, a0, e8, m1`:
  - a0 contains the AVL (number of elements to process)
  - e8 specifies SEW = 8 bits
  - m1 specifies LMUL = 1
  - t0 receives VL = min(VLEN/SEW, a0)

These formulas control how many elements are processed in each iteration of vector instructions and are essential to understanding the dynamic adaptability of RISC-V vector processing.

This document provides a step-by-step trace of the vector prefix sum algorithm execution with detailed register values at each step, focusing specifically on vector length settings.

## Input
- Let's use a small array for simplicity

- Array: [3, 1, 4, 1, 5, 9]
- Total elements (a0): 6

## Hardware Configuration
- VLEN (hardware vector register length): 32 bits (hypothetical for this example)
- SEW (selected element width): 8 bits
- Maximum vector length = VLEN/SEW = 32/8 = 4 elements per vector register

## Register Initialization
- a0 = pointer to input array [3, 1, 4, 1, 5, 9]
- a1 = pointer to output array (empty)
- a2 = 6 (number of elements)

```assembly
prefix_sum:
    mv t6, zero             # offset = 0 (initialize running sum to zero)
```
- t6 = 0 (initial offset/sum from previous chunks)

## FIRST CHUNK PROCESSING

### Vector Setup
```assembly
beqz a2, done           # a2 = 6, not zero, continue
vsetvli t0, a2, e8, m1  # Set vector length based on remaining elements
```

The `vsetvli` instruction:
- Takes the maximum number of elements (a2 = 6)
- Sets element width to 8 bits (e8)
- Sets LMUL = 1 (m1)
- Returns actual vector length in t0

Calculation:
- Vector Length = min(VLEN/SEW, a2) = min(32/8, 6) = min(4, 6) = 4
- t0 = 4 (4 elements fit in each vector register with this configuration)

### Loading Data
```assembly
vle8.v v0, (a0)         # Load first 4 elements into v0
```
- v0 = [3, 1, 4, 1]
- Only t0 (4) elements are loaded because that's the active vector length

```assembly
add a0, a0, t0          # a0 += 4 (now points to 5th element)
li t3, 1                # t3 = 1 (initial step size)
```

### Scan Phase - Building Prefix Sum Within Chunk
#### Iteration 1 (step size = 1)
```assembly
bge t3, t0, process     # t3 = 1, t0 = 4, continue scan
vslideup.vx v1, v0, t3  # Slide up elements in v0 by t3 positions
```
- v1 = [0, 3, 1, 4]
  - Element 0: Default zero (nothing slides into position 0)
  - Element 1: Value from v0[0] (3)
  - Element 2: Value from v0[1] (1)
  - Element 3: Value from v0[2] (4)

```assembly
vadd.vv v0, v0, v1      # Add corresponding elements
```
- v0 = [3, 4, 5, 5]
  - v0[0] = 3 + 0 = 3
  - v0[1] = 1 + 3 = 4
  - v0[2] = 4 + 1 = 5
  - v0[3] = 1 + 4 = 5

```assembly
slli t3, t3, 1          # t3 = 1 << 1 = 2 (double step size)
j scan
```

#### Iteration 2 (step size = 2)
```assembly
bge t3, t0, process     # t3 = 2, t0 = 4, continue scan
vslideup.vx v1, v0, t3  # Slide up elements in v0 by t3 positions
```
- v1 = [0, 0, 3, 4]
  - Element 0: Default zero
  - Element 1: Default zero
  - Element 2: Value from v0[0] (3)
  - Element 3: Value from v0[1] (4)

```assembly
vadd.vv v0, v0, v1      # Add corresponding elements
```
- v0 = [3, 4, 8, 9]
  - v0[0] = 3 + 0 = 3
  - v0[1] = 4 + 0 = 4
  - v0[2] = 5 + 3 = 8
  - v0[3] = 5 + 4 = 9

```assembly
slli t3, t3, 1          # t3 = 2 << 1 = 4 (double step size)
j scan
```

#### Iteration 3 (step size = 4)
```assembly
bge t3, t0, process     # t3 = 4, t0 = 4, exit scan (t3 >= t0)
```

### Process and Store Results
```assembly
vmv.v.x v1, t6          # v1 = [0, 0, 0, 0] (broadcast t6=0 to all lanes)
```
- This instruction copies scalar register t6 (0) to all elements of v1
- Active vector length (t0 = 4) determines how many elements are set

```assembly
vadd.vv v0, v0, v1      # v0 = [3, 4, 8, 9] (add offset to each element)
```
- No change to values since offset is 0
- This adds the running sum from previous chunks (none for first chunk)

```assembly
vse8.v v0, (a1)         # Store v0 to output array
```
- Output array now contains [3, 4, 8, 9]
- Stores t0 (4) elements because that's the active vector length

```assembly
add a1, a1, t0          # a1 += 4 (advance output pointer)
vmv.x.s t4, v0          # t4 = 9 (extract last element of v0)
```
- vmv.x.s extracts element at index t0-1 (last active element)
- This value will be used to update the running sum for the next chunk

```assembly
add t6, t6, t4          # t6 = 0 + 9 = 9 (update offset for next chunk)
sub a2, a2, t0          # a2 = 6 - 4 = 2 (remaining elements)
bnez a2, start          # a2 = 2, not zero, continue to next chunk
```

## SECOND CHUNK PROCESSING

### Vector Setup (Again)
```assembly
beqz a2, done           # a2 = 2, not zero, continue
vsetvli t0, a2, e8, m1  # Set vector length based on remaining elements
```

This is where `vsetvli` shows its power:
- With a2 now 2, `vsetvli` automatically adjusts the vector length
- Calculation: t0 = min(VLEN/SEW, a2) = min(4, 2) = 2
- This ensures we only process the remaining elements

### Loading Data
```assembly
vle8.v v0, (a0)         # Load remaining 2 elements into v0
```
- v0 = [5, 9]
- Only t0 (2) elements are loaded because the vector length is now 2
- These are the 5th and 6th elements from the original array

```assembly
add a0, a0, t0          # a0 += 2 (now at end of input)
li t3, 1                # t3 = 1 (reset step size)
```

### Scan Phase - Building Prefix Sum Within Chunk
#### Iteration 1 (step size = 1)
```assembly
bge t3, t0, process     # t3 = 1, t0 = 2, continue scan
vslideup.vx v1, v0, t3  # Slide up elements in v0 by t3 positions
```
- v1 = [0, 5]
  - Element 0: Default zero
  - Element 1: Value from v0[0] (5)

```assembly
vadd.vv v0, v0, v1      # Add corresponding elements
```
- v0 = [5, 14]
  - v0[0] = 5 + 0 = 5
  - v0[1] = 9 + 5 = 14

```assembly
slli t3, t3, 1          # t3 = 1 << 1 = 2 (double step size)
j scan
```

#### Iteration 2 (step size = 2)
```assembly
bge t3, t0, process     # t3 = 2, t0 = 2, exit scan (t3 >= t0)
```

### Process and Store Results
```assembly
vmv.v.x v1, t6          # v1 = [9, 9] (broadcast t6=9 to all lanes)
```
- This copies the scalar register t6 (9) to all elements of v1
- Only t0 (2) elements are set because that's the current vector length

```assembly
vadd.vv v0, v0, v1      # v0 = [14, 23] (add offset to each element)
```
- v0[0] = 5 + 9 = 14
- v0[1] = 14 + 9 = 23
- This is where the previous chunk's sum is incorporated

```assembly
vse8.v v0, (a1)         # Store v0 to output array
```
- Output array now contains [3, 4, 8, 9, 14, 23]
- Only stores t0 (2) elements because of the current vector length

```assembly
add a1, a1, t0          # a1 += 2 (advance output pointer)
vmv.x.s t4, v0          # t4 = 23 (extract last element of v0)
add t6, t6, t4          # t6 = 9 + 23 = 32 (update offset)
sub a2, a2, t0          # a2 = 2 - 2 = 0 (no remaining elements)
bnez a2, start          # a2 = 0, branch not taken
```

## Exit Function
```assembly
done:
ret                     # Return to caller
```

## Key Observations About Vector Length Behavior

This example demonstrates several important aspects of how vector length affects RISC-V vector processing:

1. **Dynamic Vector Length Adjustment**: The `vsetvli` instruction automatically adjusted the vector length based on:
   - Hardware vector register size (VLEN/SEW = 4 in this example)
   - Remaining elements to process (reduced to 2 for the second chunk)

2. **Consistent Code Despite Varying Vector Lengths**: The same loop code handled:
   - Full chunks (4 elements)
   - Partial chunks (2 elements at the end)

3. **Automatic Masking**: All vector operations (`vle8.v`, `vse8.v`, `vadd.vv`, etc.) automatically respected the current vector length without needing separate code paths.

4. **Efficiency of Vector Length Changes**: When the vector length changed from 4 to 2 in the second chunk, no special handling was required - the hardware automatically adjusted execution.

5. **Number of Scan Phase Iterations**: The number of scan phase iterations is logarithmic in the vector length:
   - With 4 elements, we needed 2 iterations (step sizes 1, 2)
   - With 2 elements, we needed 1 iteration (step size 1)

## Memory Trace

The vector prefix sum algorithm requires careful memory access pattern management. Here's a detailed trace of how memory is accessed:

### Memory Load Pattern
| Chunk | Elements | Values |
|-------|----------|--------|
| 1 | [0-3] | [3, 1, 4, 1] |
| 2 | [4-5] | [5, 9] |

### Memory Store Pattern
| Chunk | Values | Positions |
|-------|--------|-----------|
| 1 | [3, 4, 8, 9] | [0-3] |
| 2 | [14, 23] | [4-5] |

### Memory Access Efficiency
- Sequential access pattern for both loads and stores
- No random memory access
- Stride-1 access pattern optimal for memory bandwidth utilization
- Single-pass algorithm (each element loaded and stored exactly once)

This memory access pattern is highly cache-friendly and ensures optimal memory bandwidth utilization.

## SUMMARY OF VSETVLI USAGE

The `vsetvli` instruction is crucial to this algorithm because:

1. **Dynamic Vector Length**: It automatically adjusts the vector length based on the remaining elements, allowing the same code to handle both full and partial chunks.

2. **Tailored Processing**: In our example, it first processed 4 elements, then adjusted to process just the remaining 2 elements.

3. **Efficient Tail Handling**: Without this feature, we would need separate code to handle the "tail" elements when the number of elements isn't a multiple of the maximum vector length.

4. **Implicit Length Control**: All subsequent vector operations (vle8.v, vse8.v, vadd.vv, etc.) automatically respect the vector length set by vsetvli.

5. **Hardware Adaptability**: The same code can run efficiently on RISC-V implementations with different vector register sizes - larger registers will process more elements per chunk.

## FINAL RESULT

This produces the correct prefix sum array: [3, 4, 8, 9, 14, 23]

### Verification:
| Index | Calculation | Result |
|-------|-------------|--------|
| 0 | 3 | 3 |
| 1 | 3 + 1 | 4 |
| 2 | 3 + 1 + 4 | 8 |
| 3 | 3 + 1 + 4 + 1 | 9 |
| 4 | (3 + 1 + 4 + 1) + 5 = 9 + 5 | 14 |
| 5 | (3 + 1 + 4 + 1) + 5 + 9 = 9 + 14 | 23 |

# LMUL Optimized  aka Q4.b

If LMUL was changed to 2, it would double the effective vector register length, allowing more elements to be processed in each chunk. Here's how it would affect the algorithm:

With LMUL = 2:
- VLMAX would become 2× larger: VLMAX = VLEN/SEW × 2
- In the example, with VLEN = 32 bits and SEW = 8 bits:
  - VLMAX = 32/8 × 2 = 8 elements (instead of 4)
  - First chunk would process 8 elements (or all 6 if that's all we have)
  - The entire array [3,1,4,1,5,9] could be processed in a single chunk

This change would:
1. Reduce the number of chunks needed (possibly to just one)
2. Potentially increase performance by reducing loop iterations
3. Use more physical registers (each vector register would now occupy 2 architectural registers)
4. Allow larger step sizes in the scan phase iterations

The trade-off is that LMUL=2 reduces the number of available vector registers by half, as each vector operation now consumes twice as many physical registers.

### Physical Register Considerations

The example program doesn't explicitly account for physical register usage or potential register pressure. Here's what happens regarding physical registers:

When setting LMUL=2 (or higher):
1. Each vector register consumes LMUL physical registers
2. The total number of available vector registers is reduced from 32 to 32/LMUL
3. With LMUL=2, you'd have only 16 available vector registers instead of 32

If you run out of physical registers:
- The compiler would need to spill registers to memory, storing their contents temporarily on the stack
- This causes additional memory operations that reduce performance
- Vector spills are particularly expensive due to their size

In this specific prefix sum algorithm, register usage is minimal (mainly v0 and v1), so even with LMUL=2 or higher, register pressure isn't a concern. However, in more complex vector algorithms that use many vector registers simultaneously, higher LMUL values could lead to register spills and performance degradation.

The RISC-V vector extension allows this flexibility precisely to let programmers balance vector length against register count for optimal performance in different scenarios. 

# Masked Instructions vs. Shifts   (Q4.C)

If this RVV assembly code was rewritten to use masked instructions instead of shifts, the number of vector instructions would increase. Using masks would require additional vector instructions to generate and update the mask registers for each iteration, whereas the current implementation using vslideup efficiently handles element shifting with a single instruction per iteration. 

### Example: Shifts vs. Masks

#### Current Implementation (Using Shifts)
```assembly
# For step size = 1
vslideup.vx v1, v0, t3  # Slide up elements in v0 by t3 positions
vadd.vv v0, v0, v1      # Add corresponding elements
```

#### Alternative Implementation (Using Masks)
```assembly
# For step size = 1
vsetvli t1, t0, e8, m1  # Set vector length
vmv.v.i v1, 0           # Initialize v1 with zeros
li t2, 1                # Prepare for mask generation
vsetvli t1, t0, e8, m1, ta, ma  # Set vector length with mask agnostic
vid.v v2                # Generate vector of indices [0,1,2,3...]
vmsgt.vx v0mask, v2, t3 # Create mask where indices > step size
vmerge.vvm v1, v1, v0, v0mask  # Selectively copy elements using mask
vadd.vv v0, v0, v1      # Add corresponding elements
```

The masked version requires at least 3 additional vector instructions (vid.v, vmsgt.vx, vmerge.vvm) compared to the single vslideup.vx instruction in the shift-based approach. This demonstrates why the shift-based implementation is more efficient for this algorithm. 

# Vector Instructions Appendix 

### How vmerge.vvm Works

The `vmerge.vvm` instruction performs a masked merge operation with the following syntax:
```
vmerge.vvm vd, vs1, vs2, vm
```

Where:
- `vd` is the destination vector register
- `vs1` is the first source vector register (used when mask bit is 0)
- `vs2` is the second source vector register (used when mask bit is 1)
- `vm` is the mask register controlling the merge

For each element position i:
- If mask bit vm[i] = 1: vd[i] = vs2[i]
- If mask bit vm[i] = 0: vd[i] = vs1[i]

In our example:
- `vmerge.vvm v1, v1, v0, v0mask` means:
  - Where v0mask[i] = 1: Copy from v0[i] to v1[i]
  - Where v0mask[i] = 0: Keep original v1[i] value (which is 0)

This selectively copies elements from v0 to v1 based on the mask, which accomplishes a similar result to vslideup but requires more setup instructions to create and apply the mask. 

### Understanding vsetvli with Tail and Mask Agnostic Settings

The extended `vsetvli` instruction with tail and mask agnostic settings has the syntax:
```
vsetvli rd, rs1, vtypei, ta, ma
```

Where:
- `rd`, `rs1`, and `vtypei` work as in the basic vsetvli
- `ta` specifies the tail agnostic policy
- `ma` specifies the mask agnostic policy

These policies control how vector elements beyond the active vector length (tail elements) and masked-off elements are handled:

**Tail Agnostic (ta):**
- `tu` (tail undisturbed): Elements beyond VL retain their previous values
- `ta` (tail agnostic): Elements beyond VL are considered "don't care" and may be modified

**Mask Agnostic (ma):**
- `mu` (mask undisturbed): Masked-off elements retain their previous values
- `ma` (mask agnostic): Masked-off elements are considered "don't care" and may be modified

The formula for vector length calculation remains the same:
- VL = min(VLMAX, AVL)
- Where VLMAX = VLEN / SEW × LMUL

In our masked example:
```assembly
vsetvli t1, t0, e8, m1, ta, ma
```

This sets:
- Element width to 8 bits (e8)
- LMUL to 1 (m1)
- Tail agnostic mode (ta) - elements beyond VL may be modified
- Mask agnostic mode (ma) - masked-off elements may be modified

Using `ta` and `ma` can improve performance as the hardware doesn't need to preserve values in inactive elements. This is particularly useful in our masked implementation where we're selectively merging elements and don't care about preserving values in inactive positions. 

### How vid.v Works

The `vid.v` instruction generates a vector of indices and has the syntax:
```
vid.v vd, vm
```

Where:
- `vd` is the destination vector register
- `vm` is an optional mask (if omitted, all elements are considered active)

For each active element position i (where i is from 0 to VL-1):
- vd[i] = i

For example, with VL = 4:
- vid.v v2 produces: v2 = [0, 1, 2, 3]

This instruction is essential for creating position-dependent masks or for operations that need to know the element's position in the vector.

### How vmsgt.vx Works

The `vmsgt.vx` instruction performs an element-wise "set if greater than" comparison between a vector register and a scalar register, producing a mask. It has the syntax:
```
vmsgt.vx vd, vs2, rs1, vm
```

Where:
- `vd` is the destination mask register
- `vs2` is the vector source register
- `rs1` is the scalar source register
- `vm` is an optional mask controlling which elements participate

For each active element position i:
- vd[i] = (vs2[i] > rs1) ? 1 : 0

For example, with vs2 = [0, 1, 2, 3] and rs1 = 1:
- vmsgt.vx v0mask, v2, t3 produces: v0mask = [0, 0, 1, 1]
  - 0 > 1? No, so v0mask[0] = 0
  - 1 > 1? No, so v0mask[1] = 0
  - 2 > 1? Yes, so v0mask[2] = 1
  - 3 > 1? Yes, so v0mask[3] = 1

In our masked implementation, this creates a mask where elements at positions greater than the step size (t3) are selected, which is crucial for implementing the sliding window effect without using vslideup. 

### How vredsum Works

The `vredsum` instruction performs a vector reduction sum operation and has the syntax:
```
vredsum.vs vd, vs2, vs1, vm
```

Where:
- `vd` is the destination vector register (scalar result stored in element 0)
- `vs2` is the vector source register containing elements to sum
- `vs1` is the vector source register containing the initial sum value (in element 0)
- `vm` is an optional mask controlling which elements participate

Operation:
1. Initialize result = vs1[0]
2. For each active element i from 0 to VL-1:
   - result = result + vs2[i]
3. Store result in vd[0]
4. All other elements of vd (beyond element 0) are implementation-defined

For example, with vs2 = [3, 1, 4, 1], vs1[0] = 0, and VL = 4:
- vredsum.vs v3, v2, v1 produces: v3[0] = 0 + 3 + 1 + 4 + 1 = 9

This instruction is particularly useful for vector reduction operations where you need to compute a single result (like a sum) from all elements in a vector. In the context of a prefix sum algorithm, vredsum could be used to efficiently compute the sum of a chunk, which could then be used as the offset for the next chunk.

While not used in our original implementation, vredsum could potentially optimize the extraction of the last element's value (which we currently do with vmv.x.s after computing the full prefix sum) by directly summing all elements in the input chunk. 