/* Copyright 2019 The TensorFlow Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
==============================================================================*/
#ifndef TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_
#define TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_

#include <algorithm>

#include "tensorflow/lite/kernels/internal/common.h"
#include "tensorflow/lite/kernels/internal/portable_tensor_utils.h"
#include "riscv.h"
#include "cfu.h"
#include "perf.h"

namespace tflite {
namespace reference_integer_ops {

// Fixed-point per-channel-quantization convolution reference kernel.
inline void ConvPerChannel(
    const ConvParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int8_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_data, const RuntimeShape& bias_shape,
    const int32_t* bias_data, const RuntimeShape& output_shape,
    int8_t* output_data) {

  perf_enable_counter(6);

  // 初始化參數
  const int32_t input_offset = params.input_offset;  // r = s(q - Z)
  const int stride_width = params.stride_width;
  const int stride_height = params.stride_height;
  const int dilation_width_factor = params.dilation_width_factor;
  const int dilation_height_factor = params.dilation_height_factor;
  const int pad_width = params.padding_values.width;
  const int pad_height = params.padding_values.height;
  const int32_t output_offset = params.output_offset;

  // 設定輸出的最小與最大值
  const int32_t output_activation_min = params.quantized_activation_min;
  const int32_t output_activation_max = params.quantized_activation_max;

  // 獲取張量的維度
  const int input_depth = input_shape.Dims(3);
  const int output_depth = MatchingDim(filter_shape, 0, output_shape, 3);
  const int input_height = input_shape.Dims(1);
  const int input_width = input_shape.Dims(2);
  const int filter_height = filter_shape.Dims(1);
  const int filter_width = filter_shape.Dims(2);
  const int output_height = output_shape.Dims(1);
  const int output_width = output_shape.Dims(2);

  int8_t  im2col[592][1040];
  int8_t  kernel[592][80];
  int32_t resultmtx[1040][80];
  
  // **IM2COL 方法：加入多通道展開**
  int im2col_row = 0;
  for (int out_y = 0; out_y < output_height; out_y++) {
    const int in_y_origin = (out_y * stride_height) - pad_height;
    for (int out_x = 0; out_x < output_width; out_x++) {
      const int in_x_origin = (out_x * stride_width) - pad_width;
      for (int filter_y = 0; filter_y < filter_height; filter_y++) {
        const int in_y = in_y_origin + dilation_height_factor * filter_y;
        for (int filter_x = 0; filter_x < filter_width; filter_x++) {
          const int in_x = in_x_origin + dilation_width_factor * filter_x;

          const bool is_point_inside_image =
              ((uint32_t)in_x < (uint32_t)input_width) && ((uint32_t)in_y < (uint32_t)input_height);
              
          /*
          for (int in_channel = 0; in_channel < input_depth; in_channel++) {
            if (is_point_inside_image) {
              im2col[filter_y * filter_width * input_depth + filter_x * input_depth + in_channel][im2col_row] =
                  input_data[Offset(input_shape, 0, in_y, in_x, in_channel)];
            }
            else {
              im2col[filter_y * filter_width * input_depth + filter_x * input_depth + in_channel][im2col_row] = -input_offset;
            }
          }
          */
          // 多通道展開，處理 4 個通道
          for (int in_channel = 0; in_channel < input_depth; in_channel += 4) {
            for (int offset = 0; offset < 4; ++offset) {
              int channel_index = in_channel + offset;
              if (channel_index < input_depth) {
                im2col[filter_y * filter_width * input_depth + filter_x * input_depth + channel_index][im2col_row] =
                    is_point_inside_image
                        ? input_data[Offset(input_shape, 0, in_y, in_x, channel_index)]
                        : -input_offset;
              }
            }
          }
        }
      }
      im2col_row++;
    }
  }

  // **Kernel 濾波器展平：加入多通道展開**
  for (int out_channel = 0; out_channel < output_depth; out_channel++) {
    for (int filter_y = 0; filter_y < filter_height; filter_y++) {
      for (int filter_x = 0; filter_x < filter_width; filter_x++) {
        /*
        for (int in_channel = 0; in_channel < input_depth; in_channel++) {
          kernel[filter_y * filter_width * input_depth + filter_x * input_depth + in_channel][out_channel] =
              filter_data[Offset(filter_shape, out_channel, filter_y, filter_x, in_channel)];
        }
        */
        // 多通道展開，處理 4 個通道
        for (int in_channel = 0; in_channel < input_depth; in_channel += 4) {
          for (int offset = 0; offset < 4; ++offset) {
            int channel_index = in_channel + offset;
            if (channel_index < input_depth) {
              kernel[filter_y * filter_width * input_depth + filter_x * input_depth + channel_index][out_channel] =
                  filter_data[Offset(filter_shape, out_channel, filter_y, filter_x, channel_index)];
            }
          }
        }
      }
    }
  }

  // Tiling
  const int K = filter_height * filter_width * input_depth;
  const int M = im2col_row; //output_height * output_width;
  const int N = output_depth;
  const int A_Block = M / 16;
  const int B_Block = N / 16;

  uint32_t MandN = 0;
  int M_new = 0, N_new = 0;
  uint32_t A_idx = 0;
  // printf ("BUFFER A => %ld times\n", static_cast<uint32_t>((std::min((i+1)*MaxA_Block, A_Block)-i*MaxA_Block) * K));
  for (int col = 0; col < A_Block; col++) {
    for (int row = 0; row < K; row++) {
      uint32_t A_data1 = 0, A_data2 = 0, A_data3 = 0, A_data4 = 0;
      cfu_op3(1, A_idx, 0);
      A_data1 |= ((uint32_t)(im2col[row][col*16+0]) & 0xff) << 24;
      A_data1 |= ((uint32_t)(im2col[row][col*16+1]) & 0xff) << 16;
      A_data1 |= ((uint32_t)(im2col[row][col*16+2]) & 0xff) << 8;
      A_data1 |= ((uint32_t)(im2col[row][col*16+3]) & 0xff);
      A_data2 |= ((uint32_t)(im2col[row][col*16+4]) & 0xff) << 24;
      A_data2 |= ((uint32_t)(im2col[row][col*16+5]) & 0xff) << 16;
      A_data2 |= ((uint32_t)(im2col[row][col*16+6]) & 0xff) << 8;
      A_data2 |= ((uint32_t)(im2col[row][col*16+7]) & 0xff);
      // A_data1 |= ((im2col[row][col*16+ 0]) << 24) | ((im2col[row][col*16+ 1]) << 16) | ((im2col[row][col*16+ 2]) << 8) | ((im2col[row][col*16+ 3]));
      // A_data2 |= ((im2col[row][col*16+ 4]) << 24) | ((im2col[row][col*16+ 5]) << 16) | ((im2col[row][col*16+ 6]) << 8) | ((im2col[row][col*16+ 7]));
      cfu_op3(0, A_data1, A_data2);
      A_data3 |= ((uint32_t)(im2col[row][col*16+8]) & 0xff) << 24;
      A_data3 |= ((uint32_t)(im2col[row][col*16+9]) & 0xff) << 16;
      A_data3 |= ((uint32_t)(im2col[row][col*16+10])& 0xff) << 8;
      A_data3 |= ((uint32_t)(im2col[row][col*16+11])& 0xff);
      A_data4 |= ((uint32_t)(im2col[row][col*16+12])& 0xff) << 24;
      A_data4 |= ((uint32_t)(im2col[row][col*16+13])& 0xff) << 16;
      A_data4 |= ((uint32_t)(im2col[row][col*16+14])& 0xff) << 8;
      A_data4 |= ((uint32_t)(im2col[row][col*16+15])& 0xff);
      // A_data3 |= ((im2col[row][col*16+ 8]) << 24) | ((im2col[row][col*16+ 9]) << 16) | ((im2col[row][col*16+10]) << 8) | ((im2col[row][col*16+11]));
      // A_data4 |= ((im2col[row][col*16+12]) << 24) | ((im2col[row][col*16+13]) << 16) | ((im2col[row][col*16+14]) << 8) | ((im2col[row][col*16+15]));
      cfu_op1(0, A_data3, A_data4);
      A_idx++;
    }
  }

  uint32_t B_idx = 0;
  // printf ("BUFFER B => %ld times\n", static_cast<uint32_t>((std::min((j+1)*MaxB_Block, B_Block)-j*MaxB_Block) * K));
  for (int col = 0; col < B_Block; col++) {
    for (int row = 0; row < K; row++) {
      uint32_t B_data1 = 0, B_data2 = 0, B_data3 = 0, B_data4 = 0;
      cfu_op3(1, B_idx, 0);
      B_data1 |= ((uint32_t)(kernel[row][col*16+0]) & 0xff) << 24;
      B_data1 |= ((uint32_t)(kernel[row][col*16+1]) & 0xff) << 16;
      B_data1 |= ((uint32_t)(kernel[row][col*16+2]) & 0xff) << 8;
      B_data1 |= ((uint32_t)(kernel[row][col*16+3]) & 0xff);
      B_data2 |= ((uint32_t)(kernel[row][col*16+4]) & 0xff) << 24;
      B_data2 |= ((uint32_t)(kernel[row][col*16+5]) & 0xff) << 16;
      B_data2 |= ((uint32_t)(kernel[row][col*16+6]) & 0xff) << 8;
      B_data2 |= ((uint32_t)(kernel[row][col*16+7]) & 0xff);
      // B_data1 |= (((kernel[row][col*16+ 0])) << 24) | (((kernel[row][col*16+ 1])) << 16) | (((kernel[row][col*16+ 2])) << 8) | ((kernel[row][col*16+ 3]));
      // B_data2 |= (((kernel[row][col*16+ 4])) << 24) | (((kernel[row][col*16+ 5])) << 16) | (((kernel[row][col*16+ 6])) << 8) | ((kernel[row][col*16+ 7]));
      cfu_op3(0, B_data1, B_data2);
      B_data3 |= ((uint32_t)(kernel[row][col*16+8]) & 0xff) << 24;
      B_data3 |= ((uint32_t)(kernel[row][col*16+9]) & 0xff) << 16;
      B_data3 |= ((uint32_t)(kernel[row][col*16+10])& 0xff) << 8;
      B_data3 |= ((uint32_t)(kernel[row][col*16+11])& 0xff);
      B_data4 |= ((uint32_t)(kernel[row][col*16+12])& 0xff) << 24;
      B_data4 |= ((uint32_t)(kernel[row][col*16+13])& 0xff) << 16;
      B_data4 |= ((uint32_t)(kernel[row][col*16+14])& 0xff) << 8;
      B_data4 |= ((uint32_t)(kernel[row][col*16+15])& 0xff);
      // B_data3 |= (((kernel[row][col*16+ 8])) << 24) | (((kernel[row][col*16+ 9])) << 16) | (((kernel[row][col*16+10])) << 8) | ((kernel[row][col*16+11]));
      // B_data4 |= (((kernel[row][col*16+12])) << 24) | (((kernel[row][col*16+13])) << 16) | (((kernel[row][col*16+14])) << 8) | ((kernel[row][col*16+15]));
      cfu_op1(1, B_data3, B_data4);
      B_idx++;
    }
  }
  N_new = N;
  
  M_new = M;

  MandN = 0;
  MandN |= ((uint32_t)(M_new) & 0xffff) << 16;
  MandN |= ((uint32_t)(N_new) & 0xffff);

  cfu_op0(1, (uint32_t)K, MandN);

  uint32_t rows_c = M_new * (N_new / 16);
  for (uint32_t ii = 0; ii < rows_c; ii++) {
    resultmtx[ii%M_new][ii/M_new*16+0]  = cfu_op2(0, ii, 0);
    resultmtx[ii%M_new][ii/M_new*16+1]  = cfu_op2(0, ii, 1);
    resultmtx[ii%M_new][ii/M_new*16+2]  = cfu_op2(0, ii, 2);
    resultmtx[ii%M_new][ii/M_new*16+3]  = cfu_op2(0, ii, 3);
    resultmtx[ii%M_new][ii/M_new*16+4]  = cfu_op2(0, ii, 4);
    resultmtx[ii%M_new][ii/M_new*16+5]  = cfu_op2(0, ii, 5);
    resultmtx[ii%M_new][ii/M_new*16+6]  = cfu_op2(0, ii, 6);
    resultmtx[ii%M_new][ii/M_new*16+7]  = cfu_op2(0, ii, 7);
    resultmtx[ii%M_new][ii/M_new*16+8]  = cfu_op2(0, ii, 8);
    resultmtx[ii%M_new][ii/M_new*16+9]  = cfu_op2(0, ii, 9);
    resultmtx[ii%M_new][ii/M_new*16+10] = cfu_op2(0, ii, 10);
    resultmtx[ii%M_new][ii/M_new*16+11] = cfu_op2(0, ii, 11);
    resultmtx[ii%M_new][ii/M_new*16+12] = cfu_op2(0, ii, 12);
    resultmtx[ii%M_new][ii/M_new*16+13] = cfu_op2(0, ii, 13);
    resultmtx[ii%M_new][ii/M_new*16+14] = cfu_op2(0, ii, 14);
    resultmtx[ii%M_new][ii/M_new*16+15] = cfu_op2(0, ii, 15);
  }


  // Apply bias, activation functions, and quantization. Then reshape to output_data.
  // **後處理：保留 resultmtx_index 並加入批量處理**
  int resultmtx_index = 0;
  for (int out_y = 0; out_y < output_height; out_y++) {
    for (int out_x = 0; out_x < output_width; out_x++) {
      /*
      for (int out_channel = 0; out_channel < output_depth; out_channel++) {
        int32_t acc = resultmtx[resultmtx_index][out_channel];

        if (bias_data) {
          acc += bias_data[out_channel];
        }

        acc = MultiplyByQuantizedMultiplier(
            acc, output_multiplier[out_channel], output_shift[out_channel]);
        acc += output_offset;
        acc = std::max(acc, output_activation_min);
        acc = std::min(acc, output_activation_max);

        output_data[Offset(output_shape, 0, out_y, out_x, out_channel)] =
            static_cast<int8_t>(acc);
      }
      resultmtx_index++;
      */
      int index_base = Offset(output_shape, 0, out_y, out_x, 0); // 提前計算索引基底
      for (int out_channel = 0; out_channel < output_depth; out_channel += 4) {
        for (int offset = 0; offset < 4; ++offset) {
          int channel_index = out_channel + offset;
          if (channel_index < output_depth) {
                int32_t acc = resultmtx[resultmtx_index][channel_index];
                if (bias_data) acc += bias_data[channel_index];
                acc = MultiplyByQuantizedMultiplier(acc, output_multiplier[channel_index], output_shift[channel_index]);
                acc += output_offset;
                acc = std::min(std::max(acc, output_activation_min), output_activation_max);
                output_data[index_base + out_channel + offset] = static_cast<int8_t>(acc);
              }
        }
      }
      // 在 `out_channel` 迴圈外累加
      resultmtx_index++;
    }
  }
  perf_disable_counter(6);
}

inline void ConvPerChannelWithPackedInt4Weights(
    const ConvParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int8_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_input, int8_t* unpacked_filter_data,
    const RuntimeShape& bias_shape, const int32_t* bias_data,
    const RuntimeShape& output_shape, int8_t* output_data) {
  TFLITE_DCHECK(unpacked_filter_data != nullptr);
  tflite::tensor_utils::UnpackDenseInt4IntoInt8(
      filter_input, filter_shape.FlatSize(), unpacked_filter_data);
  ConvPerChannel(params, output_multiplier, output_shift, input_shape,
                 input_data, filter_shape, unpacked_filter_data, bias_shape,
                 bias_data, output_shape, output_data);
}

// Fixed-point per-channel-quantization convolution reference kernel.
// 16-bit data and 8-bit filter
template <typename AccumScalar>
inline void ConvPerChannel(
    const ConvParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int16_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_data, const RuntimeShape& bias_shape,
    const AccumScalar* bias_data, const RuntimeShape& output_shape,
    int16_t* output_data) {
  // Get parameters.
  const int stride_width = params.stride_width;
  const int stride_height = params.stride_height;
  const int dilation_width_factor = params.dilation_width_factor;
  const int dilation_height_factor = params.dilation_height_factor;
  const int pad_width = params.padding_values.width;
  const int pad_height = params.padding_values.height;

  // Set min and max value of the output.
  const int32_t output_activation_min = params.quantized_activation_min;
  const int32_t output_activation_max = params.quantized_activation_max;

  // Consistency check.
  TFLITE_DCHECK_LE(output_activation_min, output_activation_max);
  TFLITE_DCHECK_EQ(input_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(filter_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(output_shape.DimensionsCount(), 4);
  const int batches = MatchingDim(input_shape, 0, output_shape, 0);
  const int input_depth = input_shape.Dims(3);
  const int output_depth = MatchingDim(filter_shape, 0, output_shape, 3);
  if (bias_data) {
    TFLITE_DCHECK_EQ(bias_shape.FlatSize(), output_depth);
  }

  // Check dimensions of the tensors.
  const int input_height = input_shape.Dims(1);
  const int input_width = input_shape.Dims(2);
  const int filter_height = filter_shape.Dims(1);
  const int filter_width = filter_shape.Dims(2);
  const int filter_input_depth = filter_shape.Dims(3);
  const int groups = input_depth / filter_input_depth;
  TFLITE_DCHECK_EQ(input_depth % filter_input_depth, 0);
  const int filters_per_group = output_depth / groups;
  const int output_height = output_shape.Dims(1);
  const int output_width = output_shape.Dims(2);
  for (int batch = 0; batch < batches; ++batch) {
    for (int out_y = 0; out_y < output_height; ++out_y) {
      const int in_y_origin = (out_y * stride_height) - pad_height;
      for (int out_x = 0; out_x < output_width; ++out_x) {
        const int in_x_origin = (out_x * stride_width) - pad_width;
        for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
          auto group = out_channel / filters_per_group;
          AccumScalar acc = 0;
          for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
            const int in_y = in_y_origin + dilation_height_factor * filter_y;
            for (int filter_x = 0; filter_x < filter_width; ++filter_x) {
              const int in_x = in_x_origin + dilation_width_factor * filter_x;

              // Zero padding by omitting the areas outside the image.
              const bool is_point_inside_image =
                  (in_x >= 0) && (in_x < input_width) && (in_y >= 0) &&
                  (in_y < input_height);

              if (!is_point_inside_image) {
                continue;
              }

              for (int in_channel = 0; in_channel < filter_input_depth;
                   ++in_channel) {
                int32_t input_val =
                    input_data[Offset(input_shape, batch, in_y, in_x,
                                      in_channel + group * filter_input_depth)];
                int32_t filter_val = filter_data[Offset(
                    filter_shape, out_channel, filter_y, filter_x, in_channel)];
                // Accumulate with 64 bits accumulator.
                // int64_t += int8_t * int16_t so the highest value we can
                // get from each accumulation is [-127, 127] * ([-32768,
                // 32767] -
                // [-32768, 32767]), which is [-8322945, 8322945].
                // log2(8322945) = 22.99.
                acc += filter_val * input_val;
              }
            }
          }
          if (bias_data) {
            acc += bias_data[out_channel];
          }
          int32_t scaled_acc = MultiplyByQuantizedMultiplier(
              acc, output_multiplier[out_channel], output_shift[out_channel]);
          scaled_acc = std::max(scaled_acc, output_activation_min);
          scaled_acc = std::min(scaled_acc, output_activation_max);
          output_data[Offset(output_shape, batch, out_y, out_x, out_channel)] =
              static_cast<int16_t>(scaled_acc);
        }
      }
    }
  }
}

}  // namespace reference_integer_ops
}  // namespace tflite

#endif  // TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_
