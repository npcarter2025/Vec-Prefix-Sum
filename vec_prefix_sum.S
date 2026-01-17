// See LICENSE for license details.

//**************************************************************************
// Vectorized prefix sum
//--------------------------------------------------------------------------

    .text
    .align 2

    .global prefix_sum
    .type prefix_sum,@function
/*
 * void prefix_sum(size_t n, const uint8_t input[], uint8_t output[])
 *
 * Calling convention:
 *     
 *     a0: uint8_t *input (input array)
 *     a1: uint8_t *output (output array)
 *     a2: size_t n (number of elements)
 */
prefix_sum:
    mv t6, zero             # offset = 0

start:
    beqz a2, done           # if (n == 0), we are done
    vsetvli t0, a2, e8, m1  # set VL based on remaining elements
    vle8.v v0, (a0)         # load next chunk of input into v0
    add a0, a0, t0          # advance input pointer
    li t3, 1                # step = 1

scan:
    bge t3, t0, process     # if step >= VL, we're done with scan

    # slide up values from v0 by t3 positions
    vslideup.vx v1, v0, t3  # shift up by t3 into v1   <---ANSWER TO Q4.A   

    vadd.vv v0, v0, v1      # accumulate partial sums      
    slli t3, t3, 1          # t3 *= 2
    j scan

process:
    vmv.v.x v1, t6          # broadcast current offset to all lanes
    vadd.vv v0, v0, v1      # apply offset to v0
    vse8.v v0, (a1)         # store output vector
    add a1, a1, t0          # advance output pointer
    vmv.x.s t4, v0          # move last value in v0 to t4                ## My only confusion, I thought we wanted the VL-1 index, but I think this instruction grabs the first?
    add t6, t6, t4          # update offset for next chunk
    sub a2, a2, t0          # reduce remaining elements
    bnez a2, start

done:
    ret 