#include <utils.h>
#include <thrust/sort.h>
#include <thrust/unique.h>
#include <thrust/device_ptr.h>
#include <thrust/execution_policy.h>
#include <cuda_union_find/cuda_union_find.h>
#include <driver_types.h>

__device__ void _union_find(int *labels, int idx_1, int idx_2) {
    while(1) {
        idx_1 = labels[idx_1];
        idx_2 = labels[idx_2];
        if (idx_1 < idx_2)
            atomicMin(&labels[idx_2], idx_1);
        else if (idx_1 > idx_2)
            atomicMin(&labels[idx_1], idx_2);
        else
            break;
    }
}

template <int blk_w, int blk_h, int ch, bool ignore_labels=false>
__global__ void _local_union_find(cudaTextureObject_t in_tex, int *labels, int width, int height, float range) {
    __shared__ int blk_labels[blk_w * blk_h];
    __shared__ int blk_org_labels[blk_w * blk_h];
    __shared__ float blk_pixels[blk_w * blk_h * ch];

    int blk_x_idx = blockIdx.x * blockDim.x;
    int blk_y_idx = blockIdx.y * blockDim.y;
    int blk_size = blk_w * blk_h;
    int col = blk_x_idx + threadIdx.x;
    int row = blk_y_idx + threadIdx.y;
    int tid = threadIdx.y * blk_w + threadIdx.x;
    int gid = row * width + col;

    if (row >= height || col >= width)
        return;

    /// read labels
    blk_labels[tid] = tid;
    if (ignore_labels) {
        blk_org_labels[tid] = gid;
    }
    else {
        blk_org_labels[tid] = labels[gid];
    }

    /// read pixels
    for(int i=0; i<ch; i++) {
        blk_pixels[tid + blk_size * i] = tex2D<float>(in_tex, col, row + height * i);
    }

    __syncthreads();

    /// row scan
    float diff, diff_sum = 0;

    if (threadIdx.x != 0) {
        for (int i = 0; i < ch; i++) {
            diff = blk_pixels[tid + i * blk_size] - blk_pixels[tid - 1 + i * blk_size];
            diff_sum += diff * diff;
        }
        if (diff_sum < range)
            blk_labels[tid] = blk_labels[tid - 1];
    }
    __syncthreads();

    diff_sum = 0;
    /// column scan
    if (threadIdx.y != 0) {
        for (int i = 0; i < ch; i++) {
            diff = blk_pixels[tid + i * blk_size] - blk_pixels[tid - blk_w + i * blk_size];
            diff_sum += diff * diff;
        }
        if (diff_sum < range)
            blk_labels[tid] = blk_labels[tid - blk_w];
    }
    __syncthreads();


    /// row-column unification
    int tmp_label = tid;
    while (tmp_label != blk_labels[tmp_label]) {
        tmp_label = blk_labels[tmp_label];
    }
    blk_labels[tid] = tmp_label;

    /// local union find
    diff_sum = 0;
    if (threadIdx.x != 0) {
        for (int i = 0; i < ch; i++) {
            diff = blk_pixels[tid + i * blk_size] - blk_pixels[tid - 1 + i * blk_size];
            diff_sum += diff * diff;
        }
        if (diff_sum < range)
            _union_find(blk_labels, tid, tid - 1);
    }
    __syncthreads();

    diff_sum = 0;
    if (threadIdx.y != 0) {
        for (int i = 0; i < ch; i++) {
            diff = blk_pixels[tid + i * blk_size] - blk_pixels[tid - blk_w + i * blk_size];
            diff_sum += diff * diff;
        }
        if (diff_sum < range)
            _union_find(blk_labels, tid, tid - blk_w);
    }
    __syncthreads();

    /// store to global index
    labels[gid] = blk_org_labels[blk_labels[tid]];
}

template <int blk_w, int blk_h, int ch>
__global__ void _boundary_analysis_h(cudaTextureObject_t in_tex, int *labels, int width, int height, float range) {
    int blk_x_idx = blockIdx.x * blockDim.x;
    int blk_y_idx = blockIdx.y * blockDim.y;
    int col = blk_x_idx + threadIdx.x;
    int row = (blk_y_idx + threadIdx.y + 1) * blk_h;
    int gid = row * width + col;

    if (row >= height || col >= width)
        return;

    float diff, diff_sum = 0;
    for(int i=0; i<ch; i++) {
        diff = tex2D<float>(in_tex, col, row + height * i) - tex2D<float>(in_tex, col, row - 1 + height * i);
        diff_sum += diff * diff;
    }
    if (diff_sum < range) {
        _union_find(labels, gid, gid - width);
    }
}

template <int blk_w, int blk_h, int ch>
__global__ void _boundary_analysis_v(cudaTextureObject_t in_tex, int *labels, int width, int height, float range) {
    int blk_x_idx = blockIdx.x * blockDim.x;
    int blk_y_idx = blockIdx.y * blockDim.y;
    int col = (blk_x_idx + threadIdx.x + 1) * blk_w;
    int row = blk_y_idx + threadIdx.y;
    int gid = row * width + col;

    if (row >= height || col >= width)
        return;

    float diff, diff_sum = 0;
    for(int i=0; i<ch; i++) {
        diff = tex2D<float>(in_tex, col, row + height * i) - tex2D<float>(in_tex, col - 1, row + height * i);
        diff_sum += diff * diff;
    }
    if (diff_sum < range) {
        _union_find(labels, gid, gid - 1);
    }
}

__global__ void _global_path_compression(int *labels, int width, int height) {
    int blk_x_idx = blockIdx.x * blockDim.x;
    int blk_y_idx = blockIdx.y * blockDim.y;
    int col = blk_x_idx + threadIdx.x;
    int row = blk_y_idx + threadIdx.y;
    int gid = row * width + col;
    int label, old_label;

    if (row >= height || col >= width)
        return;

    old_label = labels[gid];
    label = labels[old_label];

    while(old_label != label) {
        old_label = label;
        label = labels[label];
    }

    __syncthreads();
    labels[gid] = label;
}

__global__ void _label_gen_map(int *labels, int *map, int count) {
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    if (gid < count) {
        map[labels[gid]] = 1;
    }
}

__global__ void _label_gen_idx(int *map, int *counter, int count) {
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    if (gid < count) {
        if (map[gid] > 0)
            map[gid] = atomicAdd(counter, 1);
        else
            map[gid] = -1;
    }
}

__global__ void _label_remap(int *labels, int *map, int count) {
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    if (gid < count) {
        labels[gid] = map[labels[gid]];
    }
}

namespace CuMeanShift {
    template <int blk_w, int blk_h, int ch, bool ign>
    void CudaUnionFind<blk_w, blk_h, ch, ign>::union_find(int *labels,
                                                          float *input,
                                                          int *new_labels,
                                                          int *label_count,
                                                          int pitch,
                                                          int width,
                                                          int height,
                                                          float range) {
        int *labels_map;

        /// create texture object
        cudaResourceDesc res_desc;
        memset(&res_desc, 0, sizeof(res_desc));
        res_desc.resType = cudaResourceTypePitch2D;
        res_desc.res.pitch2D.devPtr = input;
        res_desc.res.pitch2D.width = width;
        res_desc.res.pitch2D.height = height * ch;
        res_desc.res.pitch2D.pitchInBytes = pitch;
        res_desc.res.pitch2D.desc.f = cudaChannelFormatKindFloat;
        res_desc.res.pitch2D.desc.x = 32; // bits per channel

        cudaTextureDesc tex_desc;
        memset(&tex_desc, 0, sizeof(tex_desc));
        tex_desc.readMode = cudaReadModeElementType;
        tex_desc.addressMode[0] = cudaAddressModeBorder;
        tex_desc.addressMode[1] = cudaAddressModeBorder;
        tex_desc.filterMode = cudaFilterModePoint;

        cudaTextureObject_t in_tex = 0;
        cudaCreateTextureObject(&in_tex, &res_desc, &tex_desc, NULL);

        dim3 block_1(blk_w, blk_h);
        dim3 grid_1(CEIL(width, blk_w), CEIL(height, blk_h));
        dim3 grid_2(CEIL(width, blk_w), CEIL(FLOOR(height - 1, blk_h), blk_h));
        dim3 grid_3(CEIL(FLOOR(width - 1, blk_w), blk_w), CEIL(height, blk_h));

        if (!ign)
            cudaMemcpy(new_labels, labels, width * height * sizeof(int), cudaMemcpyDeviceToDevice);
        cudaMalloc(&labels_map, width * height * sizeof(int));

        _local_union_find<blk_w, blk_h, ch, ign><<<grid_1, block_1>>>(in_tex, new_labels, width, height, range);

        if (height > blk_h)
            _boundary_analysis_h<blk_w, blk_h, ch><<<grid_2, block_1>>>(in_tex, new_labels, width, height, range);
        if (width > blk_w)
            _boundary_analysis_v<blk_w, blk_h, ch><<<grid_3, block_1>>>(in_tex, new_labels, width, height, range);

        _global_path_compression<<<grid_1, block_1>>>(new_labels, width, height);

        cudaDeviceSynchronize();
        /// count labels & remap labels
        int *counter_dev;
        dim3 block_map(blk_w * blk_h, 1);
        dim3 grid_map(CEIL(width * height, blk_w * blk_h), 1);

        cudaMalloc(&counter_dev, sizeof(int));
        cudaMemset(counter_dev, 0, sizeof(int));
        _label_gen_map<<<grid_map, block_map>>>(new_labels, labels_map, width * height);
        _label_gen_idx<<<grid_map, block_map>>>(labels_map, counter_dev, width * height);
        _label_remap<<<grid_map, block_map>>>(new_labels, labels_map, width * height);
        cudaMemcpy(label_count, counter_dev, sizeof(int), cudaMemcpyDeviceToHost);
        cudaFree(counter_dev);

        cudaDeviceSynchronize();
        cudaDestroyTextureObject(in_tex);
        cudaFree(labels_map);
    }
}