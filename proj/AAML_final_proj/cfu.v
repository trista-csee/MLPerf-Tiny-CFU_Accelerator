/*
Modified by: [Hua-Chen Wu]
Date: [2024-12-16]
*/

// 釋放 DSP 給其他核心運算模組使用
(*use_dsp = "no"*) module Cfu (
    input               cmd_valid,
    output              cmd_ready,
    input      [9:0]    cmd_payload_function_id,
    input      [31:0]   cmd_payload_inputs_0,
    input      [31:0]   cmd_payload_inputs_1,
    output reg          rsp_valid,
    input               rsp_ready,
    output reg [31:0]   rsp_payload_outputs_0,
    input               reset,
    input               clk
);

  // 將 ADDR_BITS 定義為 localparam 提高可維護性
  localparam ADDR_BITS = 12;

  // 紀錄內部暫存狀態與訊號
  reg [9:0]             M, N, K;
  reg [8:0]             offset;
  reg                   in_valid;
  wire                  busy;
  wire                  A_wr_en, A_wr_en_sa;
  wire [ADDR_BITS-1:0]  A_index, A_index_sa;
  reg [127:0]           A_data_in;
  wire [127:0]          A_data_out;
  wire                  B_wr_en, B_wr_en_sa;
  wire [ADDR_BITS-1:0]  B_index, B_index_sa;
  reg [127:0]           B_data_in;
  wire [127:0]          B_data_out;
  wire                  C_wr_en, C_wr_en_sa;
  wire [ADDR_BITS-1:0]  C_index, C_index_sa;
  wire [511:0]          C_data_in;
  wire [511:0]          C_data_out;
  reg                   A_wr_en_cfu;
  reg [ADDR_BITS-1:0]   A_index_cfu;
  reg                   B_wr_en_cfu;
  reg [ADDR_BITS-1:0]   B_index_cfu;
  reg                   C_wr_en_cfu, C_acc_en;
  reg [ADDR_BITS-1:0]   C_index_cfu;
  

  // 維持多工的 buffer 操作
  assign A_wr_en = busy ? A_wr_en_sa : A_wr_en_cfu;
  assign A_index = busy ? A_index_sa : A_index_cfu;
  assign B_wr_en = busy ? B_wr_en_sa : B_wr_en_cfu;
  assign B_index = busy ? B_index_sa : B_index_cfu;
  assign C_wr_en = busy ? C_wr_en_sa : C_wr_en_cfu;
  assign C_index = busy ? C_index_sa : C_index_cfu;
  

  // 狀態機狀態與暫存器
  reg         writeinA_state;  // matrixA 輸入狀態
  reg         writeinB_state;  // matrixB 輸入狀態
  reg [3:0]   readout_state;   // matrixC 輸出狀態
  reg [63:0]  A_data_in_temp;
  reg [63:0]  B_data_in_temp;
  reg [31:0]  readout_value;

  // Systolic Array 和 Buffer 實例化
  SystolicArray #(.ADDR_BITS(ADDR_BITS)) sa(
    .clk(clk), .M(M), .N(N), .K(K), .offset(offset), .in_valid(in_valid),
    .acc_en(C_acc_en), .busy(busy), .A_wr_en(A_wr_en_sa), .A_index(A_index_sa),
    .A_data_in(), .A_data_out(A_data_out), .B_wr_en(B_wr_en_sa),
    .B_index(B_index_sa), .B_data_in(), .B_data_out(B_data_out),
    .C_wr_en(C_wr_en_sa), .C_index(C_index_sa), .C_data_in(C_data_in),
    .C_data_out(C_data_out));
  
  ReadBuffer #(.ADDR_BITS(ADDR_BITS), .DATA_BITS(128)) gbuff_A(
    .clk(clk), .wr_en(A_wr_en), .index(A_index),
    .data_in(A_data_in), .data_out(A_data_out));
  ReadBuffer #(.ADDR_BITS(ADDR_BITS), .DATA_BITS(128)) gbuff_B(
    .clk(clk), .wr_en(B_wr_en), .index(B_index),
    .data_in(B_data_in), .data_out(B_data_out));
  AccumulationBuffer #(.ADDR_BITS(ADDR_BITS), .DATA_BITS(512)) gbuff_C(
    .clk(clk), .wr_en(C_wr_en), .index(C_index),
    .data_in(C_data_in), .data_out(C_data_out));
  

  // SRDHM 邏輯優化：將 nudge 定義為 localparam 提高可讀性
  localparam [31:0] NEG_NUDGE = 32'hc0000001;
  localparam [31:0] POS_NUDGE = 32'h40000000;

  reg         overflow;
  reg [63:0]  ab_64;
  wire [63:0] ab_64_nudge;
  wire [31:0] srdhm;
  
  assign ab_64_nudge = $signed(ab_64) + $signed(ab_64[63] ? NEG_NUDGE : POS_NUDGE);
  assign srdhm = overflow ? 32'h7fffffff :
      ab_64_nudge[63] ? -(-ab_64_nudge >> 31) : ab_64_nudge >> 31;


  // RDBPOT 邏輯
  wire signed [31:0] mask;
  wire signed [31:0] remainder;
  wire signed [31:0] threshold;
  wire signed [31:0] rdbpot;

  assign mask = (1 << cmd_payload_inputs_1) - 1;
  assign remainder = cmd_payload_inputs_0 & mask;
  assign threshold = (mask >>> 1) + cmd_payload_inputs_0[31];
  assign rdbpot = $signed($signed(cmd_payload_inputs_0) >>> cmd_payload_inputs_1) +
                  ($signed(remainder) > $signed(threshold));
  

  // off_minmax 邏輯
  wire [31:0] add_off;
  wire [31:0] clamp_max;
  wire [31:0] clamp_min;

  assign add_off = cmd_payload_inputs_0 + cmd_payload_inputs_1;
  assign clamp_max = $signed(add_off) > $signed(-128) ? add_off : $signed(-128);
  assign clamp_min = $signed(clamp_max) < $signed(127) ? clamp_max : $signed(127);


  // post selection 邏輯
  wire [31:0] post_output;
  
  assign post_output = cmd_payload_function_id[7:3] == 6 ? srdhm :
                       cmd_payload_function_id[7:3] == 7 ? rdbpot : clamp_min;
  
  
  // 指令處理狀態機與功能
  assign cmd_ready = ~rsp_valid;

  always @(posedge clk) begin
    in_valid <= 0;

    if (reset) begin
        rsp_valid <= 1'b0;
        A_wr_en_cfu <= 0; A_index_cfu <= ~0;
        B_wr_en_cfu <= 0; B_index_cfu <= ~0;
        C_wr_en_cfu <= 0; C_index_cfu <= 0;
        writeinA_state <= 0;
        writeinB_state <= 0;
        readout_state <= 0;
    end else if (rsp_valid) begin
        rsp_valid <= ~rsp_ready;
    end else if (cmd_valid) begin
        case(cmd_payload_function_id[9:3])
            0: begin  // set_matrixA: cfu_op0(0, uval, lval)
                case(writeinA_state)
                    0: begin
                        A_wr_en_cfu <= 0;
                        A_data_in_temp <= {cmd_payload_inputs_0,
                                           cmd_payload_inputs_1};
                    end
                    1: begin
                        A_wr_en_cfu <= 1;
                        A_index_cfu <= A_index_cfu + 1;
                        A_data_in <= {A_data_in_temp,
                                      cmd_payload_inputs_0,
                                      cmd_payload_inputs_1};
                    end
                endcase

                writeinA_state <= writeinA_state + 1;
            end
            1: begin  // set_matrixB: cfu_op0(1, uval, lval)
                case(writeinB_state)
                    0: begin
                        B_wr_en_cfu <= 0;
                        B_data_in_temp <= {cmd_payload_inputs_0,
                                           cmd_payload_inputs_1};
                    end
                    1: begin
                        B_wr_en_cfu <= 1;
                        B_index_cfu <= B_index_cfu + 1;
                        B_data_in <= {B_data_in_temp,
                                      cmd_payload_inputs_0,
                                      cmd_payload_inputs_1};
                    end
                endcase

                writeinB_state <= writeinB_state + 1;
            end
            2: begin  // start_GEMM: cfu_op0(2, A<<30 | M<<20 | N<<10 | K, off)
                B_wr_en_cfu <= 0;
                A_index_cfu <= ~0; B_index_cfu <= ~0; C_index_cfu <= 0;
                in_valid <= 1;
                C_acc_en <= cmd_payload_inputs_0[30];
                M <= cmd_payload_inputs_0[29:20];
                N <= cmd_payload_inputs_0[19:10];
                K <= cmd_payload_inputs_0[9:0];
                offset <= cmd_payload_inputs_1[8:0];
            end
            3: begin  // check_GEMM: cfu_op0(3, 0, 0)
                rsp_payload_outputs_0 <= busy;
            end
            4: begin  // get_matrixC: cfu_op0(4, 0, 0)
                case(readout_state)
                    0:  readout_value <= C_data_out[479:448];
                    1:  readout_value <= C_data_out[447:416];
                    2:  readout_value <= C_data_out[415:384];
                    3:  readout_value <= C_data_out[383:352];
                    4:  readout_value <= C_data_out[351:320];
                    5:  readout_value <= C_data_out[319:288];
                    6:  readout_value <= C_data_out[287:256];
                    7:  readout_value <= C_data_out[255:224];
                    8:  readout_value <= C_data_out[223:192];
                    9:  readout_value <= C_data_out[191:160];
                    10: readout_value <= C_data_out[159:128];
                    11: readout_value <= C_data_out[127:96];
                    12: readout_value <= C_data_out[95:64];
                    13: readout_value <= C_data_out[63:32];
                    14: readout_value <= C_data_out[31:0];
                    15: C_index_cfu <= C_index_cfu + 1;
                endcase

                rsp_payload_outputs_0 <= readout_state == 0
                    ? C_data_out[511:480] : readout_value;
                readout_state <= readout_state + 1;
            end
            5: begin  // post_set_SRDHM: cfu_op0(5, a, b)
                overflow <= (cmd_payload_inputs_0 == 32'h80000000) &&
                            (cmd_payload_inputs_1 == 32'h80000000);
                ab_64 <= $signed(cmd_payload_inputs_0) *
                         $signed(cmd_payload_inputs_1);
            end
            6: begin  // post_get_SRDHM: cfu_op0(6, 0, 0)
                rsp_payload_outputs_0 <= post_output;
            end
            7: begin  // post_RDBPOT: cfu_op0(7, x, exp)
                rsp_payload_outputs_0 <= post_output;
            end
            8: begin  // post_off_minmax: cfu_op0(8, val, off)
                rsp_payload_outputs_0 <= post_output;
            end
        endcase

        rsp_valid <= 1;
    end
  end
endmodule


module SystolicArray #(parameter ADDR_BITS=8)(
    input                       clk,
    input [9:0]                 M, N, K,
    input [8:0]                 offset,
    input                       in_valid,
    input                       acc_en,
    output reg                  busy,
    output reg                  A_wr_en,
    output reg [ADDR_BITS-1:0]  A_index,
    output reg [127:0]          A_data_in,
    input [127:0]               A_data_out,
    output reg                  B_wr_en,
    output reg [ADDR_BITS-1:0]  B_index,
    output reg [127:0]          B_data_in,
    input [127:0]               B_data_out,
    output reg                  C_wr_en,
    output reg [ADDR_BITS-1:0]  C_index,
    output reg [511:0]          C_data_in,
    input [511:0]               C_data_out
);

  localparam PE_ROWS = 16; // Systolic Array 行數 (處理元素數量)

  // Backup regs
  reg [9:0]   M_r, N_r, K_r;
  reg [8:0]   offset_r;
  reg         acc_en_r;
  
  // Wires/Regs for systolic array
  wire [9:0]      cnt_M, cnt_N;  // loop induction variables
  reg [9:0]       m, n, k;       // loop induction variables
  reg [119:0]     AA[0:15];      // array from A
  reg [119:0]     BB[0:15];      // array from B
  wire [511:0]    CC[0:15];      // array to C
  reg [8:0]       a[0:15];       // input of systolic array
  reg [7:0]       b[0:15];       // input of systolic array
  reg [65:0]      state;         // state of (16xk)x(kx16) matmul
  reg             pe_rst;        // PE reset
  

  // Systolic Array 配置
  wire [8:0] h_wires[0:255]; // 水平連線
  wire [7:0] v_wires[0:255]; // 垂直連線
  
  genvar gi, gj;
  generate
    for (gi = 0; gi < PE_ROWS; gi = gi + 1) begin : row_gen
        for (gj = 0; gj < PE_ROWS; gj = gj + 1) begin : col_gen
            ProcessingElement P (
                .clk(clk),
                .rst(pe_rst),
                .left((gj == 0) ? a[gi] : h_wires[gi * PE_ROWS + gj - 1]),
                .top((gi == 0) ? b[gj] : v_wires[(gi - 1) * PE_ROWS + gj]),
                .right(h_wires[gi * PE_ROWS + gj]),
                .down(v_wires[gi * PE_ROWS + gj]),
                .acc(CC[gi][511 - gj*32 -: 32])
            );
        end
    end
  endgenerate


  // Implement control logic
  assign cnt_M = (M_r + 15) >> 4;
  assign cnt_N = (N_r + 15) >> 4;
  
  // 在模組頂層定義迴圈變數
  integer row_idx;
  always @(posedge clk) begin
    if (in_valid) begin
        busy <= 1;
        M_r <= M; K_r <= K; N_r <= N; offset_r <= offset;
        pe_rst <= 1; acc_en_r <= acc_en;

        // 清空本地緩衝區
        for (row_idx = 0; row_idx < PE_ROWS; row_idx = row_idx + 1) begin
            BB[row_idx] <= 0;
        end

        A_index <= 0; B_index <= 0;
        m <= 0; k <= 0; n <= 0;

        state <= 66'b000000000100100011010001010110011110001001101010111100110111101111;
    end else if (busy) begin
        case(state[65:64])
            2'b00: begin
                pe_rst <= 0;
                C_wr_en <= 0;

                AA[state[63:60]] <= k < K_r ? A_data_out[119:0] : 0;
                BB[state[63:60]] <= k < K_r ? B_data_out[119:0] : 0;

                // 優化 a[] 的賦值邏輯
                a[0] <= k < K_r ? $signed(A_data_out[127:120]) + $signed(offset_r) : 0;
                for (row_idx = 1; row_idx < 16; row_idx = row_idx + 1) begin
                    a[row_idx] <= $signed(AA[state[(row_idx * 4) - 1 -: 4]][127 - row_idx * 8 -: 8]) + $signed(offset_r);
                end

                // 優化 b[] 的賦值邏輯
                b[0] <= k < K_r ? B_data_out[127:120] : 0;
                for (row_idx = 1; row_idx < 16; row_idx = row_idx + 1) begin
                    b[row_idx] <= BB[state[(row_idx * 4) - 1 -: 4]][127 - row_idx * 8 -: 8];
                end


                A_index <= m*K_r + k + 1;
                B_index <= n*K_r + k + 1;
                k <= k + 1;

                if (k + 1 < K_r + 16) begin
                    state <= {2'b00, state[59:0], state[63:60]};
                end else begin
                    state <= 66'b010000000100100011010001010110011110001001101010111100110111101111;
                    C_index <= n*M_r + m*16;
                end
            end
            2'b01: begin
                C_wr_en <= 1;
                C_index <= n*M_r + m*16 + state[63:60] + 1;

                // 優化 C_data_in 的賦值邏輯
                for (row_idx = 0; row_idx < 16; row_idx = row_idx + 1) begin
                    C_data_in[511 - row_idx * 32 -: 32] <= CC[state[63:60]][511 - row_idx * 32 -: 32] +
                        (acc_en_r ? C_data_out[511 - row_idx * 32 -: 32] : 0);
                end


                if (m*16 + state[59:56] >= M_r || state[63:60] == 4'b1111) begin
                    pe_rst <= 1;

                    A_index <= n + 1 < cnt_N ? m * K_r : (m + 1) * K_r;
                    B_index <= n + 1 < cnt_N ? (n + 1) * K_r : 0;
                    k <= 0;
                    n <= n + 1 < cnt_N ? n + 1 : 0;
                    m <= n + 1 < cnt_N ? m : m + 1;

                    state <= n + 1 == cnt_N && m + 1 == cnt_M
                        ? 66'b110000000000000000000000000000000000000000000000000000000000000000
                        : 66'b000000000100100011010001010110011110001001101010111100110111101111;
                end else begin
                    state <= {2'b01, state[59:0], state[63:60]};
                end
            end
            2'b11: begin
                C_wr_en <= 0;
                C_index <= 0;
                busy <= 0;
            end
        endcase
    end
  end
endmodule


module ProcessingElement(
    input               clk,
    input               rst,
    input [8:0]         left,
    input [7:0]         top,
    output reg [8:0]    right,
    output reg [7:0]    down,
    output reg [31:0]   acc
);

  // 使用同步與非同步重置分離，提升合成效果
  always @(posedge clk or posedge rst) begin
    if (rst) begin
        // 重置時初始化為零
        right <= 9'b0;
        down <= 8'b0;
        acc <= 32'b0;
    end else begin
        // 正常操作邏輯
        acc <= $signed(acc) + $signed(left) * $signed(top);
        right <= left;
        down <= top;
    end
  end
endmodule


module ReadBuffer #(parameter ADDR_BITS=8, parameter DATA_BITS=8)(
    input                       clk,
    input                       wr_en,
    input      [ADDR_BITS-1:0]  index,
    input      [DATA_BITS-1:0]  data_in,
    output reg [DATA_BITS-1:0]  data_out
);

  localparam DEPTH = 2 ** ADDR_BITS;

  // 緩存記憶體陣列
  reg [DATA_BITS-1:0] gbuff [0:DEPTH-1];

  always @(negedge clk) begin
    if (wr_en) begin
        // 寫入資料至指定索引
        gbuff[index] <= data_in;
    end else begin
        // 讀取資料至輸出
        data_out <= gbuff[index];
    end
  end
endmodule


module AccumulationBuffer #(parameter ADDR_BITS=8, parameter DATA_BITS=8)(
    input                       clk,
    input                       wr_en,
    input      [ADDR_BITS-1:0]  index,
    input      [DATA_BITS-1:0]  data_in,
    output reg [DATA_BITS-1:0]  data_out
);

  localparam DEPTH = 2 ** ADDR_BITS;

  // 緩存記憶體陣列
  reg [DATA_BITS-1:0] gbuff [0:DEPTH-1];

  always @(negedge clk) begin
    if (wr_en) begin
        gbuff[index - 1] <= data_in;
    end

    // 讀取資料至輸出
    data_out <= gbuff[index];
  end
endmodule
