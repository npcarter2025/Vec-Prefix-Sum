// See LICENSE for license details.

//**************************************************************************
// Prefix sum benchmark
//--------------------------------------------------------------------------
//

#include "util.h"
#include "prefix_sum.h"

//--------------------------------------------------------------------------
// Input/Reference Data

#include "dataset1.h"

//--------------------------------------------------------------------------
// Main

int main(int argc, char* argv[])
{
  // Perform the prefix sum
  setStats(1);
  prefix_sum(DATA_SIZE, input_data, output_data);
  setStats(0);

  // Check the results
  return verifyUInt8(DATA_SIZE, output_data, verify_data);
} 