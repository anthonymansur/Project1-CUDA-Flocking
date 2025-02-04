#define GLM_FORCE_CUDA
#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <glm/glm.hpp>
#include "utilityCore.hpp"
#include "kernel.h"

// LOOK-2.1 potentially useful for doing grid-based neighbor search
#ifndef imax
#define imax( a, b ) ( ((a) > (b)) ? (a) : (b) )
#endif

#ifndef imin
#define imin( a, b ) ( ((a) < (b)) ? (a) : (b) )
#endif

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)

/**
* Check for CUDA errors; print and exit if there was a problem.
*/
void checkCUDAError(const char *msg, int line = -1) {
  cudaError_t err = cudaGetLastError();
  if (cudaSuccess != err) {
    if (line >= 0) {
      fprintf(stderr, "Line %d: ", line);
    }
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
    exit(EXIT_FAILURE);
  }
}


/*****************
* Configuration *
*****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 128

// LOOK-1.2 Parameters for the boids algorithm.
// These worked well in our reference implementation.
#define rule1Distance 5.0f
#define rule2Distance 3.0f
#define rule3Distance 5.0f

#define rule1Scale 0.01f
#define rule2Scale 0.1f
#define rule3Scale 0.1f

#define maxSpeed 1.0f

/*! Size of the starting area in simulation space. */
#define scene_scale 100.0f // max it out at 400.0f

/***********************************************
* Kernel state (pointers are device pointers) *
***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);

// LOOK-1.2 - These buffers are here to hold all your boid information.
// These get allocated for you in Boids::initSimulation.
// Consider why you would need two velocity buffers in a simulation where each
// boid cares about its neighbors' velocities.
// These are called ping-pong buffers.
glm::vec3 *dev_pos;
glm::vec3 *dev_vel1;
glm::vec3 *dev_vel2;

// LOOK-2.1 - these are NOT allocated for you. You'll have to set up the thrust
// pointers on your own too.

// For efficient sorting and the uniform grid. These should always be parallel.
int *dev_particleArrayIndices; // What index in dev_pos and dev_velX represents this particle?
int *dev_particleGridIndices; // What grid cell is this particle in?
// needed for use with thrust
thrust::device_ptr<int> dev_thrust_particleArrayIndices;
thrust::device_ptr<int> dev_thrust_particleGridIndices;

int *dev_gridCellStartIndices; // What part of dev_particleArrayIndices belongs
int *dev_gridCellEndIndices;   // to this cell?

// For Coherent implementation
glm::vec3* dev_pos2;
glm::vec3* dev_vel3;

// LOOK-2.1 - Grid parameters based on simulation parameters.
// These are automatically computed for you in Boids::initSimulation
int gridCellCount;
int gridSideCount;
float gridCellWidth;
float gridInverseCellWidth;
glm::vec3 gridMinimum;

/******************
* initSimulation *
******************/

__host__ __device__ unsigned int hash(unsigned int a) {
  a = (a + 0x7ed55d16) + (a << 12);
  a = (a ^ 0xc761c23c) ^ (a >> 19);
  a = (a + 0x165667b1) + (a << 5);
  a = (a + 0xd3a2646c) ^ (a << 9);
  a = (a + 0xfd7046c5) + (a << 3);
  a = (a ^ 0xb55a4f09) ^ (a >> 16);
  return a;
}

/**
* LOOK-1.2 - this is a typical helper function for a CUDA kernel.
* Function for generating a random vec3.
*/
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
  thrust::default_random_engine rng(hash((int)(index * time)));
  thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

  return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng), (float)unitDistrib(rng));
}

/**
* LOOK-1.2 - This is a basic CUDA kernel.
* CUDA kernel for generating boids with a specified mass randomly around the star.
*/
__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3 * arr, float scale) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    glm::vec3 rand = generateRandomVec3(time, index);
    arr[index].x = scale * rand.x;
    arr[index].y = scale * rand.y;
    arr[index].z = scale * rand.z;
  }
}

/**
* Initialize memory, update some globals
*/
void Boids::initSimulation(int N) {
  numObjects = N;
  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  // LOOK-1.2 - This is basic CUDA memory management and error checking.
  // Don't forget to cudaFree in  Boids::endSimulation.
  cudaMalloc((void**)&dev_pos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

  cudaMalloc((void**)&dev_vel1, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel1 failed!");

  cudaMalloc((void**)&dev_vel2, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel2 failed!");

  // LOOK-1.2 - This is a typical CUDA kernel invocation.
  kernGenerateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(1, numObjects,
    dev_pos, scene_scale);
  checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

  // LOOK-2.1 computing grid params
  gridCellWidth = 2.0f * std::max(std::max(rule1Distance, rule2Distance), rule3Distance);
  int halfSideCount = (int)(scene_scale / gridCellWidth) + 1;
  gridSideCount = 2 * halfSideCount;

  gridCellCount = gridSideCount * gridSideCount * gridSideCount;
  gridInverseCellWidth = 1.0f / gridCellWidth;
  float halfGridWidth = gridCellWidth * halfSideCount;
  gridMinimum.x -= halfGridWidth;
  gridMinimum.y -= halfGridWidth;
  gridMinimum.z -= halfGridWidth;

  // Allocate additional buffers here.
  cudaMalloc((void**)&dev_particleArrayIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleArrayIndices failed!");

  cudaMalloc((void**)&dev_particleGridIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleGridIndices failed!");

  cudaMalloc((void**)&dev_gridCellStartIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellStartIndices failed!");

  cudaMalloc((void**)&dev_gridCellEndIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellEndIndices failed!");

  cudaMalloc((void**)&dev_pos2, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos2 failed!");

  cudaMalloc((void**)&dev_vel3, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel3 failed!");

  cudaDeviceSynchronize();
}


/******************
* copyBoidsToVBO *
******************/

/**
* Copy the boid positions into the VBO so that they can be drawn by OpenGL.
*/
__global__ void kernCopyPositionsToVBO(int N, glm::vec3 *pos, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  float c_scale = -1.0f / s_scale;

  if (index < N) {
    vbo[4 * index + 0] = pos[index].x * c_scale;
    vbo[4 * index + 1] = pos[index].y * c_scale;
    vbo[4 * index + 2] = pos[index].z * c_scale;
    vbo[4 * index + 3] = 1.0f;
  }
}

__global__ void kernCopyVelocitiesToVBO(int N, glm::vec3 *vel, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  if (index < N) {
    vbo[4 * index + 0] = vel[index].x + 0.3f;
    vbo[4 * index + 1] = vel[index].y + 0.3f;
    vbo[4 * index + 2] = vel[index].z + 0.3f;
    vbo[4 * index + 3] = 1.0f;
  }
}

/**
* Wrapper for call to the kernCopyboidsToVBO CUDA kernel.
*/
void Boids::copyBoidsToVBO(float *vbodptr_positions, float *vbodptr_velocities) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernCopyPositionsToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_pos, vbodptr_positions, scene_scale);
  kernCopyVelocitiesToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_vel1, vbodptr_velocities, scene_scale);

  checkCUDAErrorWithLine("copyBoidsToVBO failed!");

  cudaDeviceSynchronize();
}


/******************
* stepSimulation *
******************/

/**
* LOOK-1.2 You can use this as a helper for kernUpdateVelocityBruteForce.
* __device__ code can be called from a __global__ context
* Compute the new velocity on the body with index `iSelf` due to the `N` boids
* in the `pos` and `vel` arrays.
*/
__device__ glm::vec3 computeVelocityChange(int N, int iSelf, const glm::vec3 *pos, 
  const glm::vec3 *vel) {
    // variables related to self boid
    glm::vec3 selfPos = pos[iSelf];
    glm::vec3 selfVel = vel[iSelf];

    // variables for rules
    glm::vec3 perceivedCenter(0.f); // for cohesion
    int numOfNeighborsForCohesion = 0;
    glm::vec3 c(0.f); // for separation
    glm::vec3 perceivedVelocity(0.f); // for alignment
    int numOfNeighborsForAlignment = 0;

    // Iterate through all boids and update the vectors declared above
    for (int i = 0; i < N; i++)
    {
        if (i == iSelf)
          continue;

        glm::vec3 boidPos = pos[i];
        glm::vec3 boidVel = vel[i];

        float distanceToSelf = glm::distance(boidPos, selfPos);

        // Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
        if (distanceToSelf < rule1Distance)
        {
          perceivedCenter += boidPos;
          numOfNeighborsForCohesion++;
        }

        // Rule 2: boids try to stay a distance d away from each other
        if (distanceToSelf < rule2Distance)
          c -= (boidPos - selfPos);

        // Rule 3: boids try to match the speed of surrounding boids
        if (distanceToSelf < rule3Distance)
        {
          perceivedVelocity += boidVel;
          numOfNeighborsForAlignment++;
        }
    }

    // Average the vectors (excluding c)
    perceivedCenter /= numOfNeighborsForCohesion;
    perceivedVelocity /= numOfNeighborsForAlignment;

    // Get the final vectors for each rule
    glm::vec3 cohesion = (perceivedCenter - selfPos) * rule1Scale;
    glm::vec3 separation = c * rule2Scale;
    glm::vec3 alignment = perceivedVelocity * rule3Scale;
    
    return selfVel + cohesion + separation + alignment;
}

/**
* Basic Flocking
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdateVelocityBruteForce(int N, glm::vec3 *pos,
  glm::vec3 *vel1, glm::vec3 *vel2) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  // Compute a new velocity based on pos and vel1
  glm::vec3 velocity = computeVelocityChange(N, index, pos, vel1);

  // Clamp the speed
  float speed = glm::length(velocity);
  if (speed > maxSpeed)
  {
    velocity = maxSpeed * glm::normalize(velocity);
  }

  // Record the new velocity into vel2. Question: why NOT vel1?
  // Answer: we don't want to overwrite the velocities that are still being
  // used by the other indices as they compute their velocity changes
  vel2[index] = velocity;
}

/**
* LOOK-1.2 Since this is pretty trivial, we implemented it for you.
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdatePos(int N, float dt, glm::vec3 *pos, glm::vec3 *vel) {
  // Update position by velocity
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  thisPos += vel[index] * dt;

  // Wrap the boids around so we don't lose them
  thisPos.x = thisPos.x < -scene_scale ? scene_scale : thisPos.x;
  thisPos.y = thisPos.y < -scene_scale ? scene_scale : thisPos.y;
  thisPos.z = thisPos.z < -scene_scale ? scene_scale : thisPos.z;

  thisPos.x = thisPos.x > scene_scale ? -scene_scale : thisPos.x;
  thisPos.y = thisPos.y > scene_scale ? -scene_scale : thisPos.y;
  thisPos.z = thisPos.z > scene_scale ? -scene_scale : thisPos.z;

  pos[index] = thisPos;
}

// LOOK-2.1 Consider this method of computing a 1D index from a 3D grid index.
// LOOK-2.3 Looking at this method, what would be the most memory efficient
//          order for iterating over neighboring grid cells?
//          for(x)
//            for(y)
//             for(z)? Or some other order?
// z-y-x to change the values with the most multiplications the least amount of times
__device__ int gridIndex3Dto1D(int x, int y, int z, int gridResolution) {
  return x + y * gridResolution + z * gridResolution * gridResolution;
}

__device__ glm::vec3 gridIndex1Dto3D(int i, int gridResolution) {
  int z = i / (gridResolution * gridResolution);
  int y = (i - (z * gridResolution * gridResolution)) / gridResolution;
  int x = i - (z * gridResolution * gridResolution) - (y * gridResolution);
  return glm::vec3(x, y, z);
}

__device__ glm::vec3 gridPosToIndex3D(const glm::vec3* gridPos, const glm::vec3* gridMin, float inverseGridWidth)
{
  glm::vec3 diff = *gridPos - *gridMin;
  glm::vec3 gridInx{ 0 };
  gridInx.x = (int) floor(diff.x * inverseGridWidth);
  gridInx.y = (int) floor(diff.y * inverseGridWidth);
  gridInx.z = (int) floor(diff.z * inverseGridWidth);
  return gridInx;
}

__global__ void kernComputeIndices(int N, int gridResolution,
  glm::vec3 gridMin, float inverseCellWidth,
  glm::vec3 *pos, int *indices, int *gridIndices) {
    // Label each boid with the index of its grid cell.
    // Set up a parallel array of integer indices as pointers to the actual
    // boid data in pos and vel1/vel2
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N)
  {
    indices[index] = index; 
    
    glm::vec3 gridLoc = floor((pos[index] - gridMin) * inverseCellWidth); // 3D grid index
    gridIndices[index] = gridIndex3Dto1D((int)gridLoc.x, (int)gridLoc.y, (int)gridLoc.z, gridResolution);
  }
}

// LOOK-2.1 Consider how this could be useful for indicating that a cell
//          does not enclose any boids
__global__ void kernResetIntBuffer(int N, int *intBuffer, int value) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    intBuffer[index] = value;
  }
}

__global__ void kernIdentifyCellStartEnd(int N, int *particleGridIndices,
  int *gridCellStartIndices, int *gridCellEndIndices) {
  // Identify the start point of each cell in the gridIndices array.
  // This is basically a parallel unrolling of a loop that goes
  // "this index doesn't match the one before it, must be a new cell!"
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  int prevIndex = index - 1;

  if (index >= N)
    return;

  int cellIndex = particleGridIndices[index];
  if (index == 0)
  {
    // This is the first boid we index
    gridCellStartIndices[cellIndex] = index;
  }
  else if (index == (N - 1))
  {
    // This is the last boid we are indexing.
    gridCellEndIndices[cellIndex] = index;
  }
  else
  {
    int prevCellIndex = particleGridIndices[prevIndex];
    if (prevCellIndex != cellIndex)
    {
      // This boid is the start of new cell
      gridCellStartIndices[cellIndex] = index;

      // Previous boid was the last boid of the previous cell
      gridCellEndIndices[prevCellIndex] = prevIndex;
    }
  }
}

__global__ void kernUpdateVelNeighborSearchScattered(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  int *particleArrayIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // Update a boid's velocity using the uniform grid to reduce
  // the number of boids that need to be checked.
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;

  if (index >= N)
    return;

  // - Identify which cells may contain neighbors. This isn't always 8.
  float neighborhoodDistance = glm::max(glm::max(rule1Distance, rule2Distance), rule3Distance);
  glm::vec3 selfPos = pos[index];

  glm::vec3 minNeighbor = selfPos - neighborhoodDistance;
  glm::vec3 maxNeighbor = selfPos + neighborhoodDistance;

  glm::vec3 minGridPos = gridPosToIndex3D(&minNeighbor, &gridMin, inverseCellWidth);
  glm::vec3 maxGridPos = gridPosToIndex3D(&maxNeighbor, &gridMin, inverseCellWidth);

  glm::vec3 selfGridPos = gridPosToIndex3D(&selfPos, &gridMin, inverseCellWidth);

  // Boids 
  glm::vec3 perceivedCenter;
  glm::vec3 c;
  glm::vec3 perceivedVelocity;
  int numOfNeighborsForCohesion = 0;
  int numOfNeighborsForAlignment = 0;
  glm::vec3 selfVel = vel1[index];

  for (int z = minGridPos.z; z <= maxGridPos.z; z++)
  {
    for (int y = minGridPos.y; y <= maxGridPos.y; y++)
    {
      for (int x = minGridPos.x; x <= maxGridPos.x; x++)
      {
        // check if out of bounds
        if (x < 0 || y < 0 || z < 0 || x > gridResolution || y > gridResolution || z > gridResolution)
          continue;

        // For each cell, read the start/end indices in the boid pointer array.
        int neighborCellIndex = gridIndex3Dto1D(x, y, z, gridResolution);
        int startInx = gridCellStartIndices[neighborCellIndex];
        int endInx = gridCellEndIndices[neighborCellIndex];
        if (startInx != -1 && endInx != -1)
        {
          // Access each boid in the cell and compute velocity change from
          // the boids rules, if this boid is within the neighborhood distance.
          for (int i = startInx; i < endInx; i++)
          {
            if (i == index)
              continue;

            int locInx = particleArrayIndices[i];

            glm::vec3 boidPos = pos[locInx];
            glm::vec3 boidVel = vel1[locInx];

            float distanceToSelf = glm::distance(boidPos, selfPos);

            // Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
            if (distanceToSelf < rule1Distance)
            {
              perceivedCenter += boidPos;
              numOfNeighborsForCohesion++;
            }

            // Rule 2: boids try to stay a distance d away from each other
            if (distanceToSelf < rule2Distance)
              c -= (boidPos - selfPos);

            // Rule 3: boids try to match the speed of surrounding boids
            if (distanceToSelf < rule3Distance)
            {
              perceivedVelocity += boidVel;
              numOfNeighborsForAlignment++;
            }
          }
        }
      }
    }
  }

  glm::vec3 cohesionVel{ 0.f };
  glm::vec3 separationVel{ 0.f };
  glm::vec3 alignmentVel{ 0.f };

  if (numOfNeighborsForCohesion > 0)
  {
    perceivedCenter /= numOfNeighborsForCohesion;
    cohesionVel = (perceivedCenter - selfPos) * rule1Scale;
  }

  separationVel = c * rule2Scale;

  if (numOfNeighborsForAlignment > 0)
  {
    perceivedVelocity /= numOfNeighborsForAlignment;
    alignmentVel = perceivedVelocity * rule3Scale;
  }

  glm::vec3 boidVelocity = selfVel + cohesionVel + separationVel + alignmentVel;

  // Clamp the speed change before putting the new speed in vel2
  // TODO: refactor
  float speed = glm::length(boidVelocity);
  if (speed > maxSpeed)
  {
    boidVelocity = maxSpeed * glm::normalize(boidVelocity);
  }

  vel2[index] = boidVelocity;
}

__global__ void kernUpdateVelNeighborSearchCoherent(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // This should be very similar to kernUpdateVelNeighborSearchScattered,
  // except with one less level of indirection.

  int index = (blockIdx.x * blockDim.x) + threadIdx.x;

  if (index >= N)
    return;

  // - Identify which cells may contain neighbors. This isn't always 8.
  float neighborhoodDistance = glm::max(glm::max(rule1Distance, rule2Distance), rule3Distance);
  glm::vec3 selfPos = pos[index];

  glm::vec3 minNeighbor = selfPos - neighborhoodDistance;
  glm::vec3 maxNeighbor = selfPos + neighborhoodDistance;

  glm::vec3 minGridPos = gridPosToIndex3D(&minNeighbor, &gridMin, inverseCellWidth);
  glm::vec3 maxGridPos = gridPosToIndex3D(&maxNeighbor, &gridMin, inverseCellWidth);

  glm::vec3 selfGridPos = gridPosToIndex3D(&selfPos, &gridMin, inverseCellWidth);

  // boids 
  glm::vec3 perceivedCenter;
  glm::vec3 c;
  glm::vec3 perceivedVelocity;
  int numOfNeighborsForCohesion = 0;
  int numOfNeighborsForAlignment = 0;
  glm::vec3 selfVel = vel1[index];

  for (int z = minGridPos.z; z <= maxGridPos.z; z++)
  {
    for (int y = minGridPos.y; y <= maxGridPos.y; y++)
    {
      for (int x = minGridPos.x; x <= maxGridPos.x; x++)
      {
        // check if out of bounds
        if (x < 0 || y < 0 || z < 0 || x > gridResolution || y > gridResolution || z > gridResolution)
          continue;

        // - For each cell, read the start/end indices in the boid pointer array.
        int neighborCellIndex = gridIndex3Dto1D(x, y, z, gridResolution);

        int startInx = gridCellStartIndices[neighborCellIndex];
        int endInx = gridCellEndIndices[neighborCellIndex];
        if (startInx != -1 && endInx != -1)
        {
          // - Access each boid in the cell and compute velocity change from
          //   the boids rules, if this boid is within the neighborhood distance.
          // TODO: refactor
          for (int i = startInx; i < endInx; i++)
          {
            if (i == index)
              continue;

            glm::vec3 boidPos = pos[i];
            glm::vec3 boidVel = vel1[i];

            float distanceToSelf = glm::distance(boidPos, selfPos);

            // Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
            if (distanceToSelf < rule1Distance)
            {
              perceivedCenter += boidPos;
              numOfNeighborsForCohesion++;
            }

            // Rule 2: boids try to stay a distance d away from each other
            if (distanceToSelf < rule2Distance)
              c -= (boidPos - selfPos);

            // Rule 3: boids try to match the speed of surrounding boids
            if (distanceToSelf < rule3Distance)
            {
              perceivedVelocity += boidVel;
              numOfNeighborsForAlignment++;
            }
          }
        }
      }
    }
  }

  glm::vec3 cohesionVel{ 0.f };
  glm::vec3 separationVel{ 0.f };
  glm::vec3 alignmentVel{ 0.f };

  if (numOfNeighborsForCohesion > 0)
  {
    perceivedCenter /= numOfNeighborsForCohesion;
    cohesionVel = (perceivedCenter - selfPos) * rule1Scale;
  }

  separationVel = c * rule2Scale;

  if (numOfNeighborsForAlignment > 0)
  {
    perceivedVelocity /= numOfNeighborsForAlignment;
    alignmentVel = perceivedVelocity * rule3Scale;
  }

  glm::vec3 boidVelocity = selfVel + cohesionVel + separationVel + alignmentVel;

  // - Clamp the speed change before putting the new speed in vel2
  // TODO: refactor
  float speed = glm::length(boidVelocity);
  if (speed > maxSpeed)
  {
    boidVelocity = maxSpeed * glm::normalize(boidVelocity);
  }

  vel2[index] = boidVelocity;
}

__global__ void kernRearrangeBuffer(glm::vec3* dst, glm::vec3* src, int* ref, int size)
{
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;

  if (index >= size)
    return;

  dst[index] = src[ref[index]];
}

__global__ void kernRevertBuffer(glm::vec3* dst, glm::vec3* src, int* ref, int size)
{
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;

  if (index >= size)
    return;

  dst[ref[index]] = src[index];
}


/**
* Step the entire N-body simulation by `dt` seconds.
*/
void Boids::stepSimulationNaive(float dt) {
  // Use the kernels you wrote to step the simulation forward in time.
  
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  // update the velocity vector
  kernUpdateVelocityBruteForce<<<fullBlocksPerGrid, blockSize>>>(numObjects, dev_pos, dev_vel1, dev_vel2);
  checkCUDAErrorWithLine("kernel kernUpdateVelocityBruteForce with dev_gridCellStartIndices failed!");

  // update the position based on the new velocity vector
  kernUpdatePos<<<fullBlocksPerGrid, blockSize>>>(numObjects, dt, dev_pos, dev_vel2);
  checkCUDAErrorWithLine("kernel kernUpdatePos with dev_gridCellStartIndices failed!");
  
  // Ping-pong the velocity buffers
  glm::vec3* temp = dev_vel1;
  dev_vel1 = dev_vel2;
  dev_vel2 = temp;
}

void Boids::stepSimulationScatteredGrid(float dt) {
  // Uniform Grid Neighbor search using Thrust sort.
  // In Parallel:

  // - label each particle with its array index as well as its grid index.
  //   Use 2x width grids.
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
  kernComputeIndices<<<fullBlocksPerGrid, blockSize>>>(
    numObjects,
    gridSideCount,
    gridMinimum,
    gridInverseCellWidth,
    dev_pos,
    dev_particleArrayIndices,
    dev_particleGridIndices
    );

  // Unstable key sort using Thrust. A stable sort isn't necessary, but you
  // are welcome to do a performance comparison.
  thrust::device_ptr<int> dev_thrust_keys(dev_particleGridIndices);
  thrust::device_ptr<int> dev_thrust_values(dev_particleArrayIndices);
  thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + numObjects, dev_thrust_values);

  // Naively unroll the loop for finding the start and end indices of each
  // cell's data pointers in the array of boid indices
  kernResetIntBuffer << <fullBlocksPerGrid, blockSize >> > (gridCellCount, dev_gridCellStartIndices, -1);
  checkCUDAErrorWithLine("kernel kernResetIntBuffer with dev_gridCellStartIndices failed!");
  kernResetIntBuffer << <fullBlocksPerGrid, blockSize >> > (gridCellCount, dev_gridCellEndIndices, -1);
  checkCUDAErrorWithLine("kernel kernResetIntBuffer with dev_gridCellEndIndices failed!");

  kernIdentifyCellStartEnd << <fullBlocksPerGrid, blockSize >> > (
    numObjects,
    dev_particleGridIndices,
    dev_gridCellStartIndices,
    dev_gridCellEndIndices);
  checkCUDAErrorWithLine("kernel kernIdentifyCellStartEnd failed!");


  // Perform velocity updates using neighbor search
  kernUpdateVelNeighborSearchScattered << <fullBlocksPerGrid, blockSize >> > (
    numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, gridCellWidth,
    dev_gridCellStartIndices, dev_gridCellEndIndices, dev_particleArrayIndices,
    dev_pos, dev_vel1, dev_vel2
    );
  checkCUDAErrorWithLine("kernel kernUpdateVelNeighborSearchScattered failed!");
 
  // Update positions
  kernUpdatePos << <fullBlocksPerGrid, blockSize >> > (numObjects, dt, dev_pos, dev_vel2);
  checkCUDAErrorWithLine("kernel kernUpdatePos failed!");

  
  // Ping-pong buffers as needed
  glm::vec3* temp = dev_vel1;
  dev_vel1 = dev_vel2;
  dev_vel2 = temp;
}

void Boids::stepSimulationCoherentGrid(float dt) {
  // start by copying Boids::stepSimulationNaiveGrid
  // Uniform Grid Neighbor search using Thrust sort on cell-coherent data.
  // In Parallel:

  // Label each particle with its array index as well as its grid index.
  // Use 2x width grids.
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
  kernComputeIndices << <fullBlocksPerGrid, blockSize >> > (
    numObjects,
    gridSideCount,
    gridMinimum,
    gridInverseCellWidth,
    dev_pos,
    dev_particleArrayIndices,
    dev_particleGridIndices
    );

  // Unstable key sort using Thrust. A stable sort isn't necessary, but you
  // are welcome to do a performance comparison.
  thrust::device_ptr<int> dev_thrust_keys(dev_particleGridIndices);
  thrust::device_ptr<int> dev_thrust_values(dev_particleArrayIndices);
  thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + numObjects, dev_thrust_values);

  // Use dev_particleArrayIndices to Rearrange dev_pos2 and dev_vel2
  kernRearrangeBuffer << <fullBlocksPerGrid, blockSize >> > (dev_pos2, dev_pos, dev_particleArrayIndices, numObjects);
  checkCUDAErrorWithLine("kernel kernRearrangeBuffer from dev_pos to dev_pos2 failed!");

  kernRearrangeBuffer << <fullBlocksPerGrid, blockSize >> > (dev_vel2, dev_vel1, dev_particleArrayIndices, numObjects);
  checkCUDAErrorWithLine("kernel kernRearrangeBuffer from dev_vel1 to dev_vel2 failed!");

  // Naively unroll the loop for finding the start and end indices of each
  // cell's data pointers in the array of boid indices
  kernResetIntBuffer << <fullBlocksPerGrid, blockSize >> > (gridCellCount, dev_gridCellStartIndices, -1);
  checkCUDAErrorWithLine("kernel kernResetIntBuffer with dev_gridCellStartIndices failed!");
  kernResetIntBuffer << <fullBlocksPerGrid, blockSize >> > (gridCellCount, dev_gridCellEndIndices, -1);
  checkCUDAErrorWithLine("kernel kernResetIntBuffer with dev_gridCellEndIndices failed!");

  kernIdentifyCellStartEnd << <fullBlocksPerGrid, blockSize >> > (
    numObjects,
    dev_particleGridIndices,
    dev_gridCellStartIndices,
    dev_gridCellEndIndices);
  checkCUDAErrorWithLine("kernel kernIdentifyCellStartEnd failed!");

  // Perform velocity updates using neighbor search
  kernUpdateVelNeighborSearchCoherent << <fullBlocksPerGrid, blockSize >> > (
    numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, gridCellWidth,
    dev_gridCellStartIndices, dev_gridCellEndIndices,
    dev_pos2, dev_vel2, dev_vel3
    );
  checkCUDAErrorWithLine("kernel kernUpdateVelNeighborSearchScattered failed!");

  // Update positions
  kernUpdatePos << <fullBlocksPerGrid, blockSize >> > (numObjects, dt, dev_pos2, dev_vel3);
  checkCUDAErrorWithLine("kernel kernUpdatePos failed!");

  // Rearrange dev_pos2 and dev_vel3 into dev_pos and dev_vel1
  kernRevertBuffer << <fullBlocksPerGrid, blockSize >> > (dev_pos, dev_pos2, dev_particleArrayIndices, numObjects);
  kernRevertBuffer << <fullBlocksPerGrid, blockSize >> > (dev_vel1, dev_vel3, dev_particleArrayIndices, numObjects);
}

void Boids::endSimulation() {
  cudaFree(dev_vel1);
  cudaFree(dev_vel2);
  cudaFree(dev_pos);

  // Free any additional buffers here.
  cudaFree(dev_particleArrayIndices);
  cudaFree(dev_particleGridIndices);
  cudaFree(dev_gridCellStartIndices);
  cudaFree(dev_gridCellEndIndices);
  cudaFree(dev_pos2);
}

void Boids::unitTest() {
  // LOOK-1.2 Feel free to write additional tests here.

  // test unstable sort
  int *dev_intKeys;
  int *dev_intValues;
  int N = 10;

  std::unique_ptr<int[]>intKeys{ new int[N] };
  std::unique_ptr<int[]>intValues{ new int[N] };

  intKeys[0] = 0; intValues[0] = 0;
  intKeys[1] = 1; intValues[1] = 1;
  intKeys[2] = 0; intValues[2] = 2;
  intKeys[3] = 3; intValues[3] = 3;
  intKeys[4] = 0; intValues[4] = 4;
  intKeys[5] = 2; intValues[5] = 5;
  intKeys[6] = 2; intValues[6] = 6;
  intKeys[7] = 0; intValues[7] = 7;
  intKeys[8] = 5; intValues[8] = 8;
  intKeys[9] = 6; intValues[9] = 9;

  cudaMalloc((void**)&dev_intKeys, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intKeys failed!");

  cudaMalloc((void**)&dev_intValues, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intValues failed!");

  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  std::cout << "before unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // How to copy data to the GPU
  cudaMemcpy(dev_intKeys, intKeys.get(), sizeof(int) * N, cudaMemcpyHostToDevice);
  cudaMemcpy(dev_intValues, intValues.get(), sizeof(int) * N, cudaMemcpyHostToDevice);

  // Wrap device vectors in thrust iterators for use with thrust.
  thrust::device_ptr<int> dev_thrust_keys(dev_intKeys);
  thrust::device_ptr<int> dev_thrust_values(dev_intValues);
  // LOOK-2.1 Example for using thrust::sort_by_key
  thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + N, dev_thrust_values);

  // How to copy data back to the CPU side from the GPU
  cudaMemcpy(intKeys.get(), dev_intKeys, sizeof(int) * N, cudaMemcpyDeviceToHost);
  cudaMemcpy(intValues.get(), dev_intValues, sizeof(int) * N, cudaMemcpyDeviceToHost);
  checkCUDAErrorWithLine("memcpy back failed!");

  std::cout << "after unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // cleanup
  cudaFree(dev_intKeys);
  cudaFree(dev_intValues);
  checkCUDAErrorWithLine("cudaFree failed!");
  return;
}
