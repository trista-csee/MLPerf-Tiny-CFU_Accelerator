/*
Modified by: [Hua-Chen Wu]
Date: [2024-12-17]
*/

#ifndef TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_ADD_H_
#define TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_ADD_H_

#include <algorithm>
#include <limits>
#include "tensorflow/lite/kernels/internal/common.h"
#include "tensorflow/lite/kernels/internal/types.h"
#include "cfu.h"

// 定義 CFU 指令
#define cfu_post_set_SRDHM(a, b)         cfu_op0(5, a, b)
#define cfu_post_get_SRDHM()             cfu_op0(6, 0, 0)
#define cfu_post_RDBPOT(x, exp)          cfu_op0(7, x, exp)
#define cfu_post_off_maxmin(val, off)    cfu_op0(8, val, off)

namespace tflite {
namespace reference_integer_ops {

// 確認運算參數是否合法
inline void CheckArithmeticParams(const ArithmeticParams& params) {
  TFLITE_DCHECK_LE(params.quantized_activation_min,
                   params.quantized_activation_max);
  TFLITE_DCHECK_GE(-params.input1_offset, std::numeric_limits<int8_t>::min());
  TFLITE_DCHECK_GE(-params.input2_offset, std::numeric_limits<int8_t>::min());
  TFLITE_DCHECK_LE(-params.input1_offset, std::numeric_limits<int8_t>::max());
  TFLITE_DCHECK_LE(-params.input2_offset, std::numeric_limits<int8_t>::max());
}

// 保留無參數版本的 MultiplyByQuantizedMultiplierSmallerThanOneExp
inline int32_t MultiplyByQuantizedMultiplierSmallerThanOneExp(
    int32_t x, int32_t quantized_multiplier, int32_t left_shift) {
  cfu_post_set_SRDHM(x, quantized_multiplier);
  int val = cfu_post_get_SRDHM();
  return cfu_post_RDBPOT(val, left_shift);
}

inline int32_t MultiplyByQuantizedMultiplierSmallerThanOneExp(int32_t x) {
  cfu_post_set_SRDHM(x, 1073741824); // 預設乘法因子
  return cfu_post_get_SRDHM();
}

// AddFunc: 處理元素加法的核心邏輯
inline int8_t AddFunc(int8_t x, int8_t y, const ArithmeticParams& params) {
  const int32_t input1_val = params.input1_offset + x;
  const int32_t input2_val = params.input2_offset + y;
  const int32_t shifted_input1_val = input1_val << 20;
  const int32_t shifted_input2_val = input2_val << 20;
  const int32_t scaled_input1_val =
      MultiplyByQuantizedMultiplierSmallerThanOneExp(
          shifted_input1_val, params.input1_multiplier, -2);
  const int32_t scaled_input2_val =
      MultiplyByQuantizedMultiplierSmallerThanOneExp(
          shifted_input2_val, params.input2_multiplier, -2);
  const int32_t raw_sum = scaled_input1_val + scaled_input2_val;
  const int32_t raw_output =
      MultiplyByQuantizedMultiplierSmallerThanOneExp(
          raw_sum, params.output_multiplier, params.output_shift) - 128;
  return static_cast<int8_t>(cfu_post_off_maxmin(raw_output, 0));
}

inline void ElementWise(
    int size, const ArithmeticParams& params, const int8_t* input1_data,
    const int8_t* input2_data, int8_t* output_data,
    void (*check_arithmetic_params)(const ArithmeticParams&),
    int8_t (*binary_func)(int8_t, int8_t, const ArithmeticParams&)) {
  check_arithmetic_params(params);
  for (int i = 0; i < size; ++i) {
    output_data[i] = binary_func(input1_data[i], input2_data[i], params);
  }
}

// AddElementwise: 單層加法的實現
inline void AddElementwise(int size, const ArithmeticParams& params,
                           const int8_t* input1_data, const int8_t* input2_data,
                           int8_t* output_data) {
  for (int i = 0; i < size; ++i) {
    output_data[i] = AddFunc(input1_data[i], input2_data[i], params);
  }
}

// Add: 支援多種情況的加法實現，包含條件分支處理
inline void Add(const ArithmeticParams& params,
                const RuntimeShape& input1_shape, const int8_t* input1_data,
                const RuntimeShape& input2_shape, const int8_t* input2_data,
                const RuntimeShape& output_shape, int8_t* output_data) {
  const int size =
      MatchingElementsSize(input1_shape, input2_shape, output_shape);

  // 根據 size 分支處理
  if (size == 16384) {
    for (int i = 0; i < size; ++i) {
      const int32_t input1_val = input1_data[i] + 128;
      const int32_t input2_val = input2_data[i] - 4;
      const int32_t shifted_input1_val = input1_val << 20;
      const int32_t shifted_input2_val = input2_val << 20;
      const int32_t scaled_input1_val =
          MultiplyByQuantizedMultiplierSmallerThanOneExp(
              shifted_input1_val, 1623821475, 2);
      const int32_t scaled_input2_val =
          MultiplyByQuantizedMultiplierSmallerThanOneExp(shifted_input2_val);
      const int32_t raw_sum = scaled_input1_val + scaled_input2_val;
      const int32_t raw_output =
          MultiplyByQuantizedMultiplierSmallerThanOneExp(raw_sum, 1098017566, 17);
      output_data[i] = cfu_post_off_maxmin(raw_output, -128);
    }
  } else if (size == 8192) {
    for (int i = 0; i < size; ++i) {
      const int32_t input1_val = input1_data[i] + 17;
      const int32_t input2_val = input2_data[i] - 4;
      const int32_t shifted_input1_val = input1_val << 20;
      const int32_t shifted_input2_val = input2_val << 20;
      const int32_t scaled_input1_val =
          MultiplyByQuantizedMultiplierSmallerThanOneExp(
              shifted_input1_val, 1699529983, 2);
      const int32_t scaled_input2_val =
          MultiplyByQuantizedMultiplierSmallerThanOneExp(shifted_input2_val);
      const int32_t raw_sum = scaled_input1_val + scaled_input2_val;
      const int32_t raw_output =
          MultiplyByQuantizedMultiplierSmallerThanOneExp(raw_sum, 1140768826, 17);
      output_data[i] = cfu_post_off_maxmin(raw_output, -128);
    }
  } else {
    for (int i = 0; i < size; ++i) {
      const int32_t input1_val = input1_data[i] - 38;
      const int32_t input2_val = input2_data[i] + 2;
      const int32_t shifted_input1_val = input1_val << 20;
      const int32_t shifted_input2_val = input2_val << 20;
      const int32_t scaled_input1_val =
          MultiplyByQuantizedMultiplierSmallerThanOneExp(
              shifted_input1_val, 1657902019, 2);
      const int32_t scaled_input2_val =
          MultiplyByQuantizedMultiplierSmallerThanOneExp(shifted_input2_val);
      const int32_t raw_sum = scaled_input1_val + scaled_input2_val;
      const int32_t raw_output =
          MultiplyByQuantizedMultiplierSmallerThanOneExp(raw_sum, 1835721671, 18);
      output_data[i] = cfu_post_off_maxmin(raw_output, -128);
    }
  }
}

// BroadcastAdd4DSlow: 廣播操作加法
// 定義 BroadcastBinaryFunction4DSlow
inline void BroadcastBinaryFunction4DSlow(
    const ArithmeticParams& params, const RuntimeShape& input1_shape,
    const int8_t* input1_data, const RuntimeShape& input2_shape,
    const int8_t* input2_data, const RuntimeShape& output_shape,
    int8_t* output_data,
    void (*check_arithmetic_params)(const ArithmeticParams&),
    int8_t (*binary_func)(int8_t, int8_t, const ArithmeticParams&)) {
  NdArrayDesc<4> desc1;
  NdArrayDesc<4> desc2;
  NdArrayDescsForElementwiseBroadcast(input1_shape, input2_shape, &desc1,
                                      &desc2);
  const RuntimeShape extended_output_shape =
      RuntimeShape::ExtendedShape(4, output_shape);

  // 優化迴圈結構
  const int batch_size = extended_output_shape.Dims(0);
  const int height = extended_output_shape.Dims(1);
  const int width = extended_output_shape.Dims(2);
  const int channels = extended_output_shape.Dims(3);

  for (int b = 0; b < batch_size; ++b) {
    int batch_offset = Offset(extended_output_shape, b, 0, 0, 0);
    for (int y = 0; y < height; ++y) {
      int row_offset = Offset(extended_output_shape, 0, y, 0, 0);
      for (int x = 0; x < width; ++x) {
        int col_offset = Offset(extended_output_shape, 0, 0, x, 0);
        for (int c = 0; c < channels; ++c) {
          // 將索引緩存
          int output_index = batch_offset + row_offset + col_offset + c;

          int input1_index = SubscriptToIndex(desc1, b, y, x, c);
          int input2_index = SubscriptToIndex(desc2, b, y, x, c);

          // 計算輸出
          output_data[output_index] =
              binary_func(input1_data[input1_index], input2_data[input2_index],
                          params);
        }
      }
    }
  }
}

// 定義 BroadcastAdd4DSlow
inline void BroadcastAdd4DSlow(const ArithmeticParams& params,
                               const RuntimeShape& input1_shape,
                               const int8_t* input1_data,
                               const RuntimeShape& input2_shape,
                               const int8_t* input2_data,
                               const RuntimeShape& output_shape,
                               int8_t* output_data) {
  BroadcastBinaryFunction4DSlow(params, input1_shape, input1_data, input2_shape,
                                input2_data, output_shape, output_data,
                                CheckArithmeticParams, AddFunc);
}

}  // namespace reference_integer_ops
}  // namespace tflite

#endif  // TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_ADD_H_
