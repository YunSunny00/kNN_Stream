/*
 * nn.cu
 * Nearest Neighbor
 *
 */

#include <stdio.h>
#include <sys/time.h>
#include <float.h>
#include <vector>
#include "cuda.h"

// #include "timing.h"
#include <sys/time.h>

struct timeval tv;
struct timeval tv_total_start, tv_total_end;
struct timeval tv_h2d_start, tv_h2d_end;
struct timeval tv_d2h_start, tv_d2h_end;
struct timeval tv_kernel_start, tv_kernel_end;
struct timeval tv_mem_alloc_start, tv_mem_alloc_end;
struct timeval tv_close_start, tv_close_end;
float init_time = 0, mem_alloc_time = 0, h2d_time = 0, kernel_time = 0,
       findlowest_time = 0, d2h_time = 0, close_time = 0, total_time = 0;

#define min( a, b )			a > b ? b : a
#define ceilDiv( a, b )		( a + b - 1 ) / b
#define print( x )			printf( #x ": %lu\n", (unsigned long) x )
#define DEBUG				false

#define DEFAULT_THREADS_PER_BLOCK 256

#define MAX_ARGS 10
#define REC_LENGTH 53 // size of a record in db
#define LATITUDE_POS 28	// character position of the latitude value in each record
#define OPEN 10000	// initial value of nearest neighbors


typedef struct latLong
{
  float lat;
  float lng;
} LatLong;

typedef struct record
{
  char recString[REC_LENGTH];
  float distance;
} Record;

int loadData(char *filename,std::vector<Record> &records,std::vector<LatLong> &locations);
void findLowest(std::vector<Record> &records,float *distances,int numRecords,int topN);
void printUsage();
int parseCommandline(int argc, char *argv[], char* filename,int *r,float *lat,float *lng,
                     int *q, int *t, int *p, int *d);
float timeGPU(struct timeval start, struct timeval end);

/**
* Kernel
* Executed on GPU
* Calculates the Euclidean distance from each record in the database to the target position
*/
__global__ void euclid(LatLong *d_locations, float *d_distances, int numRecords, float lat, float lng)
{
	//int globalId = gridDim.x * blockDim.x * blockIdx.y + blockDim.x * blockIdx.x + threadIdx.x;
	int globalId = blockDim.x * ( gridDim.x * blockIdx.y + blockIdx.x ) + threadIdx.x; // more efficient
  if (globalId < numRecords) {
    LatLong *latLong = d_locations+globalId;
    float *dist=d_distances+globalId;
    *dist = (float)((lat-latLong->lat)*(lat-latLong->lat)+(lng-latLong->lng)*(lng-latLong->lng));
	}
}

/**
* This program finds the k-nearest neighbors
**/

int main(int argc, char* argv[])
{
	int    i=0;
	float lat, lng;
	int quiet=0,timing=0,platform=0,device=0;

  std::vector<Record> records;
	std::vector<LatLong> locations;
	char filename[100];
	int resultsCount=10;

  // parse command line
  if (parseCommandline(argc, argv, filename,&resultsCount,&lat,&lng,
                    &quiet, &timing, &platform, &device)) {
    printUsage();
    return 0;
  }

  int numRecords = loadData(filename,records,locations);
  if (resultsCount > numRecords) resultsCount = numRecords;

  //for(i=0;i<numRecords;i++)
  //  printf("%s, %f, %f\n",(records[i].recString),locations[i].lat,locations[i].lng);


  //Pointers to host memory
	float *distances;
	//Pointers to device memory
	LatLong *d_locations;
  Record *d_records;
	float *d_distances;
  // initialize streams
  const int numStreams = 8;
  cudaStream_t streams[numStreams];
  for (int i = 0; i < numStreams; ++i) {
    cudaStreamCreate(&streams[i]);
  }
  int chunkSize = numRecords / numStreams;

	// Scaling calculations - added by Sam Kauffman
	cudaDeviceProp deviceProp;
	cudaGetDeviceProperties( &deviceProp, 0 );
	cudaThreadSynchronize();
	unsigned long maxGridX = deviceProp.maxGridSize[0];
	unsigned long threadsPerBlock = min( deviceProp.maxThreadsPerBlock, DEFAULT_THREADS_PER_BLOCK );
	size_t totalDeviceMemory;
	size_t freeDeviceMemory;
	cudaMemGetInfo(  &freeDeviceMemory, &totalDeviceMemory );
	cudaThreadSynchronize();
	unsigned long usableDeviceMemory = freeDeviceMemory * 85 / 100; // 85% arbitrary throttle to compensate for known CUDA bug
	unsigned long maxThreads = usableDeviceMemory / 12; // 4 bytes in 3 vectors per thread
	if ( numRecords > maxThreads )
	{
		fprintf( stderr, "Error: Input too large.\n" );
		exit( 1 );
	}
	unsigned long blocks = ceilDiv( numRecords, threadsPerBlock ); // extra threads will do nothing
	unsigned long gridY = ceilDiv( blocks, maxGridX );
	unsigned long gridX = ceilDiv( blocks, gridY );
	// There will be no more than (gridY - 1) extra blocks
	dim3 gridDim( gridX, gridY );

	if ( DEBUG )
	{
		print( totalDeviceMemory ); // 804454400
		print( freeDeviceMemory );
		print( usableDeviceMemory );
		print( maxGridX ); // 65535
		print( deviceProp.maxThreadsPerBlock ); // 1024
		print( threadsPerBlock );
		print( maxThreads );
		print( blocks ); // 130933
		print( gridY );
		print( gridX );
	}

	/**
	* Allocate memory on host and device
	*/
	distances = (float *)malloc(sizeof(float) * numRecords);
  cudaHostRegister(distances, sizeof(float) * numRecords, cudaHostRegisterDefault);
  if (numStreams > 1)
    cudaHostRegister(&locations[0], sizeof(float) * numRecords, cudaHostRegisterDefault);
	cudaMalloc((void **) &d_locations,sizeof(LatLong) * numRecords);
  cudaMalloc((void **) &d_records,sizeof(Record) * numRecords);
	cudaMalloc((void **) &d_distances,sizeof(float) * numRecords);

   /**
    * Transfer data from host to device
    */
  gettimeofday(&tv_h2d_start, NULL);
  // cudaMemcpy( d_locations, &locations[0], sizeof(LatLong) * numRecords, cudaMemcpyHostToDevice);
  gettimeofday(&tv_h2d_end, NULL);
  h2d_time += timeGPU(tv_h2d_start, tv_h2d_end);
  
  const int ITER = 1;
  for (int j = 0; j < ITER; j++) {
    /**
    * Execute kernel
    */
    gettimeofday(&tv_kernel_start, NULL);
    for (int k = 0; k < numStreams; k++) {
      int offset = k * chunkSize;
      if (k == numStreams - 1)
        chunkSize = numRecords - offset;
      // Asynchronously copy data to the GPU
      cudaMemcpyAsync(&d_locations[offset], &locations[offset], chunkSize * sizeof(LatLong), cudaMemcpyHostToDevice, streams[k]);
      // Launch kernel in the stream
      euclid<<<gridDim, threadsPerBlock, 0, streams[k]>>>(&d_locations[offset], &d_distances[offset], chunkSize, lat, lng);

      // Asynchronously copy results back to host
      cudaMemcpyAsync(&distances[offset], &d_distances[offset], chunkSize * sizeof(float), cudaMemcpyDeviceToHost, streams[k]);
    }
    cudaDeviceSynchronize();
    gettimeofday(&tv_kernel_end, NULL);
    kernel_time += timeGPU(tv_kernel_start, tv_kernel_end);
  }
  
  gettimeofday(&tv_kernel_start, NULL);
  //Copy data from device memory to host memory
  gettimeofday(&tv_kernel_end, NULL);
  d2h_time += timeGPU(tv_kernel_start, tv_kernel_end);
  gettimeofday(&tv_d2h_start, NULL);
  // find the resultsCount least distances
  findLowest(records,distances,numRecords,resultsCount);
  gettimeofday(&tv_d2h_end, NULL);
  findlowest_time += timeGPU(tv_d2h_start, tv_d2h_end);
  // print out results
  if (!quiet)
  for(i=0;i<resultsCount;i++) {
    printf("%s --> Distance=%f\n",records[i].recString,records[i].distance);
  }
  free(distances);
    //Free memory
  for (int i = 0; i < numStreams; ++i) {
    cudaStreamDestroy(streams[i]);
  }
	cudaFree(d_locations);
	cudaFree(d_distances);

  kernel_time = kernel_time / ITER;
  total_time = kernel_time + findlowest_time + h2d_time + d2h_time;
  printf("Total: %f\n", total_time);
  printf("h2d: %f\n", h2d_time);
  printf("kernel: %f\n", kernel_time);
  printf("d2h: %f\n", d2h_time);
  printf("findlowest: %f\n", findlowest_time);
}

int loadData(char *filename,std::vector<Record> &records,std::vector<LatLong> &locations){
    FILE   *flist,*fp;
	int    i=0;
	char dbname[64];
	int recNum=0;

    /**Main processing **/

    flist = fopen(filename, "r");
	while(!feof(flist)) {
		/**
		* Read in all records of length REC_LENGTH
		* If this is the last file in the filelist, then done
		* else open next file to be read next iteration
		*/
		if(fscanf(flist, "%s\n", dbname) != 1) {
            fprintf(stderr, "error reading filelist\n");
            exit(0);
        }
        fp = fopen(dbname, "r");
        if(!fp) {
            printf("error opening a db\n");
            exit(1);
        }
        // read each record
        while(!feof(fp)){
            Record record;
            LatLong latLong;
            fgets(record.recString,49,fp);
            fgetc(fp); // newline
            if (feof(fp)) break;

            // parse for lat and long
            char substr[6];

            for(i=0;i<5;i++) substr[i] = *(record.recString+i+28);
            substr[5] = '\0';
            latLong.lat = atof(substr);

            for(i=0;i<5;i++) substr[i] = *(record.recString+i+33);
            substr[5] = '\0';
            latLong.lng = atof(substr);

            locations.push_back(latLong);
            records.push_back(record);
            recNum++;
        }
        fclose(fp);
    }
    fclose(flist);
//    for(i=0;i<rec_count*REC_LENGTH;i++) printf("%c",sandbox[i]);
    return recNum;
}

void findLowest(std::vector<Record> &records,float *distances,int numRecords,int topN){
  int i,j;
  float val;
  int minLoc;
  Record *tempRec;
  float tempDist;

  for(i=0;i<topN;i++) {
    minLoc = i;
    for(j=i;j<numRecords;j++) {
      val = distances[j];
      if (val < distances[minLoc]) minLoc = j;
    }
    // swap locations and distances
    tempRec = &records[i];
    records[i] = records[minLoc];
    records[minLoc] = *tempRec;

    tempDist = distances[i];
    distances[i] = distances[minLoc];
    distances[minLoc] = tempDist;

    // add distance to the min we just found
    records[i].distance = distances[i];
  }
}

int parseCommandline(int argc, char *argv[], char* filename,int *r,float *lat,float *lng,
                     int *q, int *t, int *p, int *d){
    int i;
    if (argc < 2) return 1; // error
    strncpy(filename,argv[1],100);
    char flag;

    for(i=1;i<argc;i++) {
      if (argv[i][0]=='-') {// flag
        flag = argv[i][1];
          switch (flag) {
            case 'r': // number of results
              i++;
              *r = atoi(argv[i]);
              break;
            case 'l': // lat or lng
              if (argv[i][2]=='a') {//lat
                *lat = atof(argv[i+1]);
              }
              else {//lng
                *lng = atof(argv[i+1]);
              }
              i++;
              break;
            case 'h': // help
              return 1;
            case 'q': // quiet
              *q = 1;
              break;
            case 't': // timing
              *t = 1;
              break;
            case 'p': // platform
              i++;
              *p = atoi(argv[i]);
              break;
            case 'd': // device
              i++;
              *d = atoi(argv[i]);
              break;
        }
      }
    }
    if ((*d >= 0 && *p<0) || (*p>=0 && *d<0)) // both p and d must be specified if either are specified
      return 1;
    return 0;
}

void printUsage(){
  printf("Nearest Neighbor Usage\n");
  printf("\n");
  printf("nearestNeighbor [filename] -r [int] -lat [float] -lng [float] [-hqt] [-p [int] -d [int]]\n");
  printf("\n");
  printf("example:\n");
  printf("$ ./nearestNeighbor filelist.txt -r 5 -lat 30 -lng 90\n");
  printf("\n");
  printf("filename     the filename that lists the data input files\n");
  printf("-r [int]     the number of records to return (default: 10)\n");
  printf("-lat [float] the latitude for nearest neighbors (default: 0)\n");
  printf("-lng [float] the longitude for nearest neighbors (default: 0)\n");
  printf("\n");
  printf("-h, --help   Display the help file\n");
  printf("-q           Quiet mode. Suppress all text output.\n");
  printf("-t           Print timing information.\n");
  printf("\n");
  printf("-p [int]     Choose the platform (must choose both platform and device)\n");
  printf("-d [int]     Choose the device (must choose both platform and device)\n");
  printf("\n");
  printf("\n");
  printf("Notes: 1. The filename is required as the first parameter.\n");
  printf("       2. If you declare either the device or the platform,\n");
  printf("          you must declare both.\n\n");
}

float timeGPU(struct timeval start, struct timeval end) {
  struct timeval tv;
  tv.tv_sec = end.tv_sec - start.tv_sec;
  tv.tv_usec = end.tv_usec - start.tv_usec;
  return tv.tv_sec * 1000.0 + (float) tv.tv_usec / 1000.0;
}