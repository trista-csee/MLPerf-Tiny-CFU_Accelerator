// Copyright 2021 The CFU-Playground Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// invoke TPU_16
module Cfu (
    input               cmd_valid,
    output reg          cmd_ready,
    input      [9:0]    cmd_payload_function_id,
    input      [31:0]   cmd_payload_inputs_0,
    input      [31:0]   cmd_payload_inputs_1,
    output reg          rsp_valid,
    input               rsp_ready,
    output reg [31:0]   rsp_payload_outputs_0,
    input               reset,
    input               clk
);

  wire A_wr_en, B_wr_en, C_wr_en;
  wire [13:0] A_index;
  wire [11:0] B_index;
  wire [10:0] C_index;
  wire [127:0] A_data_in, B_data_in;
  wire [127:0] A_data_out, B_data_out;
  wire [511:0] C_data_in;
  wire [511:0] C_data_out;

  wire rst_n = ~reset;
  wire in_valid;
  wire offset_valid;
  wire [9:0] K;
  wire [10:0] M;
  wire [8:0] N;
  wire busy;

  wire Awr_tpu, Bwr_tpu, Cwr_tpu;
  wire [13:0] Aidx_tpu;
  wire [11:0] Bidx_tpu;
  wire [10:0] Cidx_tpu;
  wire [127:0] Adata_tpu, Bdata_tpu;
  wire [511:0] Cdata_tpu;

  // invoke the TPU_16 module
  global_buffer_bram #(
    .ADDR_BITS(14),
    .DATA_BITS(128)
  )
  gbuff_A(
    .clk(clk),
    .rst_n(1'b1),
    .ram_en(1'b1),
    .wr_en(A_wr_en),
    .index(A_index),
    .data_in(A_data_in),
    .data_out(A_data_out)
  );

  global_buffer_bram #(
    .ADDR_BITS(12),
    .DATA_BITS(128)
  )
  gbuff_B(
    .clk(clk),
    .rst_n(1'b1),
    .ram_en(1'b1),
    .wr_en(B_wr_en),
    .index(B_index),
    .data_in(B_data_in),
    .data_out(B_data_out)
  );

  global_buffer_bram #(
    .ADDR_BITS(11),
    .DATA_BITS(512)
  )
  gbuff_C(
    .clk(clk),
    .rst_n(1'b1),
    .ram_en(1'b1),
    .wr_en(C_wr_en),
    .index(C_index),
    .data_in(C_data_in),
    .data_out(C_data_out)
  );

  TPU_16 TPU16_inst(
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(in_valid),
    .offset_valid(offset_valid),
    .K(K),
    .M(M),
    .N(N),
    .busy(busy),
    .A_wr_en(Awr_tpu),
    .A_index(Aidx_tpu),
    .A_data_in(Adata_tpu),
    .A_data_out(A_data_out),
    .B_wr_en(Bwr_tpu),
    .B_index(Bidx_tpu),
    .B_data_in(Bdata_tpu),
    .B_data_out(B_data_out),
    .C_wr_en(Cwr_tpu),
    .C_index(Cidx_tpu),
    .C_data_in(Cdata_tpu),
    .C_data_out(C_data_out)
  );


  wire [6:0] func7 = cmd_payload_function_id[9:3]; 
  wire [2:0] func3 = cmd_payload_function_id[2:0]; // opcode

  reg tpu_invalid;
  reg tpu_offsetvalid;
  reg [9:0] tpu_K;
  reg [10:0] tpu_M;
  reg [8:0] tpu_N;

  reg [13:0] temp_idx;
  reg [31:0] temp_value0, temp_value1;

  reg Awr_cpu, Bwr_cpu, Cwr_cpu;
  reg [13:0] Aidx_cpu;
  reg [11:0] Bidx_cpu;
  reg [10:0] Cidx_cpu;
  reg [127:0] Adata_cpu, Bdata_cpu;
  reg [511:0] Cdata_cpu;

  reg Awr, Bwr, Cwr;
  reg [13:0] Aidx;
  reg [11:0] Bidx;
  reg [10:0] Cidx;
  reg [127:0] Adata, Bdata;
  reg [511:0] Cdata;

  parameter IDLE  = 0;
  parameter READ  = 1;
  parameter WRITE = 2;
  parameter MULT  = 3;
  parameter OUTT  = 4;
  parameter DONE  = 5;

  reg [2:0] state, state_nxt;

  // func3: 0 => Multiplication
  // func3: 1 => Write (CPU  -> BRAM)
  // func3: 2 => Read  (BRAM -> CPU)
  // func3: 3 => Temporary Register for index and value
  always @(*) begin
    case (state)
      IDLE: begin
        if (cmd_valid) begin
          case (func3[1:0])
            2'b00:  state_nxt = MULT;
            2'b01:  state_nxt = WRITE;
            2'b10:  state_nxt = READ;
            2'b11:  state_nxt = DONE;
          endcase
        end
        else state_nxt = IDLE;
      end
      
      READ: state_nxt = OUTT;
      WRITE:state_nxt = DONE;
      MULT: state_nxt = busy ? MULT : DONE;
      OUTT: state_nxt = IDLE;
      DONE: state_nxt = IDLE;

      default:  state_nxt = IDLE;

    endcase
  end

  always @(posedge clk) begin
    if (reset) 
      state <= IDLE;
    else 
      state <= state_nxt;
  end

  reg [31:0] i0, i1;
  always @(posedge clk) begin
    if (reset)
      i1 <= 0;
    else begin
      if (cmd_valid) 
        i1 <= cmd_payload_inputs_1;
      else 
        i1 <= i1;
    end
  end

  // Matrix Multiplication
  always @(*) begin
    tpu_invalid = state == IDLE && state_nxt == MULT ? 'b1 : 'b0;
    tpu_offsetvalid = state == IDLE && state_nxt == MULT ? func7[0] : tpu_offsetvalid;
    tpu_K = state == IDLE && state_nxt == MULT ? cmd_payload_inputs_0[9:0] : 0;
    tpu_M = state == IDLE && state_nxt == MULT ? cmd_payload_inputs_1[26:16] : 0;
    tpu_N = state == IDLE && state_nxt == MULT ? cmd_payload_inputs_1[8:0] : 0;
  end

  assign in_valid = tpu_invalid;
  assign offset_valid = tpu_offsetvalid;
  assign K = tpu_K;
  assign M = tpu_M;
  assign N = tpu_N;

  // Temporary Register
  always @(posedge clk) begin
    if (reset) begin
      temp_idx <= 0;
      temp_value0 <= 0;
      temp_value1 <= 0;
    end
    else begin
      if (state == IDLE && state_nxt == DONE) begin
        if (func7[0]) begin
          temp_idx <= cmd_payload_inputs_0[13:0];
          temp_value0 <= temp_value0;
          temp_value1 <= temp_value1;
        end
        else begin
          temp_idx <= temp_idx;
          temp_value0 <= cmd_payload_inputs_0;
          temp_value1 <= cmd_payload_inputs_1;
        end
      end
      else begin
        temp_idx <= temp_idx;
        temp_value0 <= temp_value0;
        temp_value1 <= temp_value1;
      end
    end
  end

  // Write Buffer A & Buffer B from CPU
  always @(posedge clk) begin
    if (reset) begin
        Awr_cpu <= 'b0;
        Aidx_cpu <= 14'b11_1111_1111_1111;
        Adata_cpu <= 0;

        Bwr_cpu <= 'b0;
        Bidx_cpu <= 12'b1111_1111_1111;
        Bdata_cpu <= 0;
    end
    else begin
      if (state == IDLE && state_nxt == WRITE) begin
        Awr_cpu <= |func7 ? 'b0 : 'b1;
        Aidx_cpu <= |func7 ? 0 : temp_idx;//Aidx_cpu : Aidx_cpu + 1;
        Adata_cpu <= |func7 ? 0 : {temp_value0, temp_value1, cmd_payload_inputs_0, cmd_payload_inputs_1};

        Bwr_cpu <= |func7 ? 'b1 : 'b0;
        Bidx_cpu <= |func7 ? temp_idx : 0;//Bidx_cpu + 1 : Bidx_cpu;
        Bdata_cpu <= |func7 ? {temp_value0, temp_value1, cmd_payload_inputs_0, cmd_payload_inputs_1} : 0;
      end
      else begin
        Awr_cpu <= 'b0;
        Aidx_cpu <= Aidx_cpu;
        Adata_cpu <= 0;

        Bwr_cpu <= 'b0;
        Bidx_cpu <= Bidx_cpu;
        Bdata_cpu <= 0;
      end
    end
  end

  // Read Buffer C from CPU
  always @(posedge clk) begin
    if (reset) begin
      Cwr_cpu <= 'b0;
      Cidx_cpu <= 0;
      Cdata_cpu <= 0;
    end
    else begin
      if (state == IDLE && state_nxt == READ) begin
        Cwr_cpu <= 'b0;
        Cidx_cpu <= cmd_payload_inputs_0[10:0];
        Cdata_cpu <= 0;
      end
      else begin
        Cwr_cpu <= 'b0;
        Cidx_cpu <= 0;
        Cdata_cpu <= 0;
      end
    end
  end

  // CFU IO
  always @(*) begin
    cmd_ready = state == IDLE ? 'b1 : 'b0;
    rsp_valid = state == OUTT || state == DONE ? 'b1 : 'b0;
  end

  always @(posedge clk) begin
    if (reset) rsp_payload_outputs_0 <= 0;
    else begin
      if (state_nxt == OUTT) begin
        case (i1)
          'd0:  rsp_payload_outputs_0 <= C_data_out[511:480];
          'd1:  rsp_payload_outputs_0 <= C_data_out[479:448];
          'd2:  rsp_payload_outputs_0 <= C_data_out[447:416];
          'd3:  rsp_payload_outputs_0 <= C_data_out[415:384];
          'd4:  rsp_payload_outputs_0 <= C_data_out[383:352];
          'd5:  rsp_payload_outputs_0 <= C_data_out[351:320];
          'd6:  rsp_payload_outputs_0 <= C_data_out[319:288];
          'd7:  rsp_payload_outputs_0 <= C_data_out[287:256];
          'd8:  rsp_payload_outputs_0 <= C_data_out[255:224];
          'd9:  rsp_payload_outputs_0 <= C_data_out[223:192];
          'd10:  rsp_payload_outputs_0 <= C_data_out[191:160];
          'd11:  rsp_payload_outputs_0 <= C_data_out[159:128];
          'd12:  rsp_payload_outputs_0 <= C_data_out[127:96];
          'd13:  rsp_payload_outputs_0 <= C_data_out[95:64];
          'd14: rsp_payload_outputs_0 <= C_data_out[63:32];
          'd15: rsp_payload_outputs_0 <= C_data_out[31:0];

          default:rsp_payload_outputs_0 <= 1;

        endcase
      end
      else if (state_nxt == DONE) 
        rsp_payload_outputs_0 <= ~32'd0;
      else 
        rsp_payload_outputs_0 <= 0;
    end
  end

  // Interface
  always @(*) begin
    if (state == MULT) begin
      Awr = Awr_tpu;
      Bwr = Bwr_tpu;
      Cwr = Cwr_tpu;

      Aidx = Aidx_tpu;
      Bidx = Bidx_tpu;
      Cidx = Cidx_tpu;

      Adata = Adata_tpu;
      Bdata = Bdata_tpu;
      Cdata = Cdata_tpu;
    end
    else begin
      Awr = Awr_cpu;
      Bwr = Bwr_cpu;
      Cwr = Cwr_cpu;

      Aidx = Aidx_cpu;
      Bidx = Bidx_cpu;
      Cidx = Cidx_cpu;

      Adata = Adata_cpu;
      Bdata = Bdata_cpu;
      Cdata = Cdata_cpu;
    end
  end

  assign A_wr_en = Awr;
  assign B_wr_en = Bwr;
  assign C_wr_en = Cwr;
  assign A_index = Aidx;
  assign B_index = Bidx;
  assign C_index = Cidx;
  assign A_data_in = Adata;
  assign B_data_in = Bdata;
  assign C_data_in = Cdata;
endmodule

/* invoke TPU_12
module Cfu (
    input               cmd_valid,
    output reg          cmd_ready,
    input      [9:0]    cmd_payload_function_id,
    input      [31:0]   cmd_payload_inputs_0,
    input      [31:0]   cmd_payload_inputs_1,
    output reg          rsp_valid,
    input               rsp_ready,
    output reg [31:0]   rsp_payload_outputs_0,
    input               reset,
    input               clk
);

  wire A_wr_en, B_wr_en, C_wr_en;
  wire [13:0] A_index;
  wire [11:0] B_index;
  wire [10:0] C_index;

  wire [95:0] A_data_in, B_data_in; //127
  wire [95:0] A_data_out, B_data_out; //127
  wire [383:0] C_data_in; //511
  wire [383:0] C_data_out; //511

  wire rst_n = ~reset;
  wire in_valid;
  wire offset_valid;
  wire [9:0] K;
  wire [10:0] M;
  wire [8:0] N;
  wire busy;

  wire Awr_tpu, Bwr_tpu, Cwr_tpu;
  wire [13:0] Aidx_tpu;
  wire [11:0] Bidx_tpu;
  wire [10:0] Cidx_tpu;

  wire [95:0] Adata_tpu, Bdata_tpu; //127
  wire [383:0] Cdata_tpu; //511

  // invoke the TPU_12 module
  global_buffer_bram #(
    .ADDR_BITS(14),
    .DATA_BITS(96)
  )
  gbuff_A(
    .clk(clk),
    .rst_n(1'b1),
    .ram_en(1'b1),
    .wr_en(A_wr_en),
    .index(A_index),
    .data_in(A_data_in),
    .data_out(A_data_out)
  );

  global_buffer_bram #(
    .ADDR_BITS(12),
    .DATA_BITS(96)
  )
  gbuff_B(
    .clk(clk),
    .rst_n(1'b1),
    .ram_en(1'b1),
    .wr_en(B_wr_en),
    .index(B_index),
    .data_in(B_data_in),
    .data_out(B_data_out)
  );

  global_buffer_bram #(
    .ADDR_BITS(11),
    .DATA_BITS(384)
  )
  gbuff_C(
    .clk(clk),
    .rst_n(1'b1),
    .ram_en(1'b1),
    .wr_en(C_wr_en),
    .index(C_index),
    .data_in(C_data_in),
    .data_out(C_data_out)
  );

  TPU_12 TPU12_inst(
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(in_valid),
    .offset_valid(offset_valid),
    .K(K),
    .M(M),
    .N(N),
    .busy(busy),
    .A_wr_en(Awr_tpu),
    .A_index(Aidx_tpu),
    .A_data_in(Adata_tpu),
    .A_data_out(A_data_out),
    .B_wr_en(Bwr_tpu),
    .B_index(Bidx_tpu),
    .B_data_in(Bdata_tpu),
    .B_data_out(B_data_out),
    .C_wr_en(Cwr_tpu),
    .C_index(Cidx_tpu),
    .C_data_in(Cdata_tpu),
    .C_data_out(C_data_out)
  );


  wire [6:0] func7 = cmd_payload_function_id[9:3]; 
  wire [2:0] func3 = cmd_payload_function_id[2:0]; // opcode

  reg tpu_invalid;
  reg tpu_offsetvalid;
  reg [9:0] tpu_K;
  reg [10:0] tpu_M;
  reg [8:0] tpu_N;

  reg [13:0] temp_idx;
  reg [31:0] temp_value0, temp_value1;

  reg Awr_cpu, Bwr_cpu, Cwr_cpu;
  reg [13:0] Aidx_cpu;
  reg [11:0] Bidx_cpu;
  reg [10:0] Cidx_cpu;

  reg [95:0] Adata_cpu, Bdata_cpu; //127
  reg [383:0] Cdata_cpu; //511

  reg Awr, Bwr, Cwr;
  reg [13:0] Aidx;
  reg [11:0] Bidx;
  reg [10:0] Cidx;

  reg [95:0] Adata, Bdata; //127
  reg [383:0] Cdata; //511

  parameter IDLE  = 0;
  parameter READ  = 1;
  parameter WRITE = 2;
  parameter MULT  = 3;
  parameter OUTT  = 4;
  parameter DONE  = 5;

  reg [2:0] state, state_nxt;

  // func3: 0 => Multiplication
  // func3: 1 => Write (CPU  -> BRAM)
  // func3: 2 => Read  (BRAM -> CPU)
  // func3: 3 => Temporary Register for index and value
  always @(*) begin
    case (state)
      IDLE: begin
        if (cmd_valid) begin
          case (func3[1:0])
            2'b00:  state_nxt = MULT;
            2'b01:  state_nxt = WRITE;
            2'b10:  state_nxt = READ;
            2'b11:  state_nxt = DONE;
          endcase
        end
        else state_nxt = IDLE;
      end
      
      READ: state_nxt = OUTT;
      WRITE:state_nxt = DONE;
      MULT: state_nxt = busy ? MULT : DONE;
      OUTT: state_nxt = IDLE;
      DONE: state_nxt = IDLE;

      default:  state_nxt = IDLE;

    endcase
  end

  always @(posedge clk) begin
    if (reset) 
      state <= IDLE;
    else 
      state <= state_nxt;
  end

  reg [31:0] i0, i1;
  always @(posedge clk) begin
    if (reset)
      i1 <= 0;
    else begin
      if (cmd_valid) 
        i1 <= cmd_payload_inputs_1;
      else 
        i1 <= i1;
    end
  end

  // Matrix Multiplication
  always @(*) begin
    tpu_invalid = state == IDLE && state_nxt == MULT ? 'b1 : 'b0;
    tpu_offsetvalid = state == IDLE && state_nxt == MULT ? func7[0] : tpu_offsetvalid;
    tpu_K = state == IDLE && state_nxt == MULT ? cmd_payload_inputs_0[9:0] : 0;
    tpu_M = state == IDLE && state_nxt == MULT ? cmd_payload_inputs_1[26:16] : 0;
    tpu_N = state == IDLE && state_nxt == MULT ? cmd_payload_inputs_1[8:0] : 0;
  end

  assign in_valid = tpu_invalid;
  assign offset_valid = tpu_offsetvalid;
  assign K = tpu_K;
  assign M = tpu_M;
  assign N = tpu_N;

  // Temporary Register
  always @(posedge clk) begin
    if (reset) begin
      temp_idx <= 0;
      temp_value0 <= 0;
      temp_value1 <= 0;
    end
    else begin
      if (state == IDLE && state_nxt == DONE) begin
        if (func7[0]) begin
          temp_idx <= cmd_payload_inputs_0[13:0];
          temp_value0 <= temp_value0;
          temp_value1 <= temp_value1;
        end
        else begin
          temp_idx <= temp_idx;
          temp_value0 <= cmd_payload_inputs_0;
          temp_value1 <= cmd_payload_inputs_1;
        end
      end
      else begin
        temp_idx <= temp_idx;
        temp_value0 <= temp_value0;
        temp_value1 <= temp_value1;
      end
    end
  end

  // Write Buffer A & Buffer B from CPU
  always @(posedge clk) begin
    if (reset) begin
        Awr_cpu <= 'b0;
        Aidx_cpu <= 14'b11_1111_1111_1111;
        Adata_cpu <= 0;

        Bwr_cpu <= 'b0;
        Bidx_cpu <= 12'b1111_1111_1111;
        Bdata_cpu <= 0;
    end
    else begin
      if (state == IDLE && state_nxt == WRITE) begin
        Awr_cpu <= |func7 ? 'b0 : 'b1;
        Aidx_cpu <= |func7 ? 0 : temp_idx;//Aidx_cpu : Aidx_cpu + 1;
        Adata_cpu <= |func7 ? 0 : {temp_value0, temp_value1, cmd_payload_inputs_0, cmd_payload_inputs_1};

        Bwr_cpu <= |func7 ? 'b1 : 'b0;
        Bidx_cpu <= |func7 ? temp_idx : 0;//Bidx_cpu + 1 : Bidx_cpu;
        Bdata_cpu <= |func7 ? {temp_value0, temp_value1, cmd_payload_inputs_0, cmd_payload_inputs_1} : 0;
      end
      else begin
        Awr_cpu <= 'b0;
        Aidx_cpu <= Aidx_cpu;
        Adata_cpu <= 0;

        Bwr_cpu <= 'b0;
        Bidx_cpu <= Bidx_cpu;
        Bdata_cpu <= 0;
      end
    end
  end

  // Read Buffer C from CPU
  always @(posedge clk) begin
    if (reset) begin
      Cwr_cpu <= 'b0;
      Cidx_cpu <= 0;
      Cdata_cpu <= 0;
    end
    else begin
      if (state == IDLE && state_nxt == READ) begin
        Cwr_cpu <= 'b0;
        Cidx_cpu <= cmd_payload_inputs_0[10:0];
        Cdata_cpu <= 0;
      end
      else begin
        Cwr_cpu <= 'b0;
        Cidx_cpu <= 0;
        Cdata_cpu <= 0;
      end
    end
  end

  // CFU IO
  always @(*) begin
    cmd_ready = state == IDLE ? 'b1 : 'b0;
    rsp_valid = state == OUTT || state == DONE ? 'b1 : 'b0;
  end

  always @(posedge clk) begin
    if (reset) rsp_payload_outputs_0 <= 0;
    else begin
      if (state_nxt == OUTT) begin
        case (i1)
          'd0:  rsp_payload_outputs_0 <= C_data_out[383:352];
          'd1:  rsp_payload_outputs_0 <= C_data_out[351:320];
          'd2:  rsp_payload_outputs_0 <= C_data_out[319:288];
          'd3:  rsp_payload_outputs_0 <= C_data_out[287:256];
          'd4:  rsp_payload_outputs_0 <= C_data_out[255:224];
          'd5:  rsp_payload_outputs_0 <= C_data_out[223:192];
          'd6:  rsp_payload_outputs_0 <= C_data_out[191:160];
          'd7:  rsp_payload_outputs_0 <= C_data_out[159:128];
          'd8:  rsp_payload_outputs_0 <= C_data_out[127:96];
          'd9:  rsp_payload_outputs_0 <= C_data_out[95:64];
          'd10: rsp_payload_outputs_0 <= C_data_out[63:32];
          'd11: rsp_payload_outputs_0 <= C_data_out[31:0];

          default:rsp_payload_outputs_0 <= 1;

        endcase
      end
      else if (state_nxt == DONE) 
        rsp_payload_outputs_0 <= ~32'd0;
      else 
        rsp_payload_outputs_0 <= 0;
    end
  end

  // Interface
  always @(*) begin
    if (state == MULT) begin
      Awr = Awr_tpu;
      Bwr = Bwr_tpu;
      Cwr = Cwr_tpu;

      Aidx = Aidx_tpu;
      Bidx = Bidx_tpu;
      Cidx = Cidx_tpu;

      Adata = Adata_tpu;
      Bdata = Bdata_tpu;
      Cdata = Cdata_tpu;
    end
    else begin
      Awr = Awr_cpu;
      Bwr = Bwr_cpu;
      Cwr = Cwr_cpu;

      Aidx = Aidx_cpu;
      Bidx = Bidx_cpu;
      Cidx = Cidx_cpu;

      Adata = Adata_cpu;
      Bdata = Bdata_cpu;
      Cdata = Cdata_cpu;
    end
  end

  assign A_wr_en = Awr;
  assign B_wr_en = Bwr;
  assign C_wr_en = Cwr;
  assign A_index = Aidx;
  assign B_index = Bidx;
  assign C_index = Cidx;
  assign A_data_in = Adata;
  assign B_data_in = Bdata;
  assign C_data_in = Cdata;
endmodule
*/

// invoke the Systolic_array_16 module
module TPU_16(
    clk,
    rst_n,
    in_valid,
    offset_valid,
    K,
    M,
    N,
    busy,
    A_wr_en,
    A_index,
    A_data_in,
    A_data_out,
    B_wr_en,
    B_index,
    B_data_in,
    B_data_out,
    C_wr_en,
    C_index,
    C_data_in,
    C_data_out
);

  input             clk;
  input             rst_n;
  input             in_valid;
  input             offset_valid;
  input [9:0]       K;
  input [10:0]      M;
  input [8:0]       N;
  output  reg       busy;
  output            A_wr_en;
  output reg [13:0] A_index;
  output [127:0]     A_data_in;
  input  [127:0]     A_data_out;
  output            B_wr_en;
  output reg [11:0] B_index;
  output [127:0]     B_data_in;
  input  [127:0]     B_data_out;
  output            C_wr_en;
  output [10:0]     C_index;
  output [511:0]    C_data_in;
  input  [511:0]    C_data_out;


  reg [511:0] data_write;
  
  // ========== FSM ==========
  reg [1:0] state;
  parameter IDLE = 0;
  parameter FEED = 1;
  parameter CALC = 3;
  
  // ========== Signals ==========
  reg [9:0] K_reg;
  reg [9:0] k_times;
  reg [9:0] cnt_k;
  
  reg [10:0] M_reg;
  reg [6:0] m_times, m_comb;
  reg [6:0] cnt_m;

  wire [10:0] m0 = {cnt_m, 4'h0};
  wire [10:0] m1 = {cnt_m, 4'h1};
  wire [10:0] m2 = {cnt_m, 4'h2};
  wire [10:0] m3 = {cnt_m, 4'h3};
  wire [10:0] m4 = {cnt_m, 4'h4};
  wire [10:0] m5 = {cnt_m, 4'h5};
  wire [10:0] m6 = {cnt_m, 4'h6};
  wire [10:0] m7 = {cnt_m, 4'h7};
  wire [10:0] m8 = {cnt_m, 4'h8};
  wire [10:0] m9 = {cnt_m, 4'h9};
  wire [10:0] m10= {cnt_m, 4'ha};
  wire [10:0] m11= {cnt_m, 4'hb};
  wire [10:0] m12= {cnt_m, 4'hc};
  wire [10:0] m13= {cnt_m, 4'hd};
  wire [10:0] m14= {cnt_m, 4'he};
  wire [10:0] m15= {cnt_m, 4'hf};
  
  reg [8:0] N_reg;
  reg [2:0] n_times, n_comb;
  reg [2:0] cnt_n;
  
  reg cal_rst, sys_rst;

  reg valid0, valid1, valid2, valid3, valid4, valid5, valid6, valid7, valid8, valid9, valid10, valid11, valid12, valid13, valid14, valid15;
  reg valid1_ff0, valid2_ff0, valid3_ff0, valid4_ff0, valid5_ff0, valid6_ff0, valid7_ff0, valid8_ff0, valid9_ff0, valid10_ff0, valid11_ff0, valid12_ff0, valid13_ff0, valid14_ff0, valid15_ff0;
  reg valid2_ff1, valid3_ff1, valid4_ff1, valid5_ff1, valid6_ff1, valid7_ff1, valid8_ff1, valid9_ff1, valid10_ff1, valid11_ff1, valid12_ff1, valid13_ff1, valid14_ff1, valid15_ff1;
  reg valid3_ff2, valid4_ff2, valid5_ff2, valid6_ff2, valid7_ff2, valid8_ff2, valid9_ff2, valid10_ff2, valid11_ff2, valid12_ff2, valid13_ff2, valid14_ff2, valid15_ff2;
  reg valid4_ff3, valid5_ff3, valid6_ff3, valid7_ff3, valid8_ff3, valid9_ff3, valid10_ff3, valid11_ff3, valid12_ff3, valid13_ff3, valid14_ff3, valid15_ff3;
  reg valid5_ff4, valid6_ff4, valid7_ff4, valid8_ff4, valid9_ff4, valid10_ff4, valid11_ff4, valid12_ff4, valid13_ff4, valid14_ff4, valid15_ff4;
  reg valid6_ff5, valid7_ff5, valid8_ff5, valid9_ff5, valid10_ff5, valid11_ff5, valid12_ff5, valid13_ff5, valid14_ff5, valid15_ff5;
  reg valid7_ff6, valid8_ff6, valid9_ff6, valid10_ff6, valid11_ff6, valid12_ff6, valid13_ff6, valid14_ff6, valid15_ff6;
  reg valid8_ff7, valid9_ff7, valid10_ff7, valid11_ff7, valid12_ff7, valid13_ff7, valid14_ff7, valid15_ff7;
  reg valid9_ff8, valid10_ff8, valid11_ff8, valid12_ff8, valid13_ff8, valid14_ff8, valid15_ff8;
  reg valid10_ff9, valid11_ff9, valid12_ff9, valid13_ff9, valid14_ff9, valid15_ff9;
  reg valid11_ff10, valid12_ff10, valid13_ff10, valid14_ff10, valid15_ff10;
  reg valid12_ff11, valid13_ff11, valid14_ff11, valid15_ff11;
  reg valid13_ff12, valid14_ff12, valid15_ff12;
  reg valid14_ff13, valid15_ff13;
  reg valid15_ff14;
  
  reg [7:0] row0, row1, row2, row3, row4, row5, row6, row7, row8, row9, row10, row11, row12, row13, row14, row15;
  reg [7:0] row1_ff0, row2_ff0, row3_ff0, row4_ff0, row5_ff0, row6_ff0, row7_ff0, row8_ff0, row9_ff0, row10_ff0, row11_ff0, row12_ff0, row13_ff0, row14_ff0, row15_ff0;
  reg [7:0] row2_ff1, row3_ff1, row4_ff1, row5_ff1, row6_ff1, row7_ff1, row8_ff1, row9_ff1, row10_ff1, row11_ff1, row12_ff1, row13_ff1, row14_ff1, row15_ff1;
  reg [7:0] row3_ff2, row4_ff2, row5_ff2, row6_ff2, row7_ff2, row8_ff2, row9_ff2, row10_ff2, row11_ff2, row12_ff2, row13_ff2, row14_ff2, row15_ff2;
  reg [7:0] row4_ff3, row5_ff3, row6_ff3, row7_ff3, row8_ff3, row9_ff3, row10_ff3, row11_ff3, row12_ff3, row13_ff3, row14_ff3, row15_ff3;
  reg [7:0] row5_ff4, row6_ff4, row7_ff4, row8_ff4, row9_ff4, row10_ff4, row11_ff4, row12_ff4, row13_ff4, row14_ff4, row15_ff4;
  reg [7:0] row6_ff5, row7_ff5, row8_ff5, row9_ff5, row10_ff5, row11_ff5, row12_ff5, row13_ff5, row14_ff5, row15_ff5;
  reg [7:0] row7_ff6, row8_ff6, row9_ff6, row10_ff6, row11_ff6, row12_ff6, row13_ff6, row14_ff6, row15_ff6;
  reg [7:0] row8_ff7, row9_ff7, row10_ff7, row11_ff7, row12_ff7, row13_ff7, row14_ff7, row15_ff7;
  reg [7:0] row9_ff8, row10_ff8, row11_ff8, row12_ff8, row13_ff8, row14_ff8, row15_ff8;
  reg [7:0] row10_ff9, row11_ff9, row12_ff9, row13_ff9, row14_ff9, row15_ff9;
  reg [7:0] row11_ff10, row12_ff10, row13_ff10, row14_ff10, row15_ff10;
  reg [7:0] row12_ff11, row13_ff11, row14_ff11, row15_ff11;
  reg [7:0] row13_ff12, row14_ff12, row15_ff12;
  reg [7:0] row14_ff13, row15_ff13;
  reg [7:0] row15_ff14;
  
  reg [7:0] col0, col1, col2, col3, col4, col5, col6, col7, col8, col9, col10, col11, col12, col13, col14, col15;
  reg [7:0] col1_ff0, col2_ff0, col3_ff0, col4_ff0, col5_ff0, col6_ff0, col7_ff0, col8_ff0, col9_ff0, col10_ff0, col11_ff0, col12_ff0, col13_ff0, col14_ff0, col15_ff0;
  reg [7:0] col2_ff1, col3_ff1, col4_ff1, col5_ff1, col6_ff1, col7_ff1, col8_ff1, col9_ff1, col10_ff1, col11_ff1, col12_ff1, col13_ff1, col14_ff1, col15_ff1;
  reg [7:0] col3_ff2, col4_ff2, col5_ff2, col6_ff2, col7_ff2, col8_ff2, col9_ff2, col10_ff2, col11_ff2, col12_ff2, col13_ff2, col14_ff2, col15_ff2;
  reg [7:0] col4_ff3, col5_ff3, col6_ff3, col7_ff3, col8_ff3, col9_ff3, col10_ff3, col11_ff3, col12_ff3, col13_ff3, col14_ff3, col15_ff3;
  reg [7:0] col5_ff4, col6_ff4, col7_ff4, col8_ff4, col9_ff4, col10_ff4, col11_ff4, col12_ff4, col13_ff4, col14_ff4, col15_ff4;
  reg [7:0] col6_ff5, col7_ff5, col8_ff5, col9_ff5, col10_ff5, col11_ff5, col12_ff5, col13_ff5, col14_ff5, col15_ff5;
  reg [7:0] col7_ff6, col8_ff6, col9_ff6, col10_ff6, col11_ff6, col12_ff6, col13_ff6, col14_ff6, col15_ff6;
  reg [7:0] col8_ff7, col9_ff7, col10_ff7, col11_ff7, col12_ff7, col13_ff7, col14_ff7, col15_ff7;
  reg [7:0] col9_ff8, col10_ff8, col11_ff8, col12_ff8, col13_ff8, col14_ff8, col15_ff8;
  reg [7:0] col10_ff9, col11_ff9, col12_ff9, col13_ff9, col14_ff9, col15_ff9;
  reg [7:0] col11_ff10, col12_ff10, col13_ff10, col14_ff10, col15_ff10;
  reg [7:0] col12_ff11, col13_ff11, col14_ff11, col15_ff11;
  reg [7:0] col13_ff12, col14_ff12, col15_ff12;
  reg [7:0] col14_ff13, col15_ff13;
  reg [7:0] col15_ff14;

  reg [15:0] valid_bus;
  reg [127:0] a_bus, b_bus;
  wire [15:0] out_valid;
  wire [511:0] result0, result1, result2, result3, result4, result5, result6, result7, result8, result9, result10, result11, result12, result13, result14, result15;

  wire eq_k, eq_m, eq_n;
  reg grabbing;
  wire end_feeding;
  wire end_calculating;
  
  reg eq_k_ff0, eq_k_ff1;
  reg r0_done, r1_done, r2_done, r3_done, r4_done, r5_done, r6_done, r7_done, r8_done, r9_done, r10_done, r11_done, r12_done, r13_done, r14_done, r15_done;
  reg [15:0] idx_c;
  wire [15:0] write_valid;


  // ========== State ==========
  always @(posedge clk) begin
    if (!rst_n) state <= IDLE;
    else begin
        case (state)
        IDLE:   state <= in_valid ? FEED : IDLE;
        FEED:   state <= end_feeding ? CALC : FEED;
        CALC:   state <= end_calculating ? IDLE : CALC;
        endcase
    end
  end

  // ========== Registers ==========
  always @(posedge clk) begin
    if (!rst_n) begin
      K_reg <= 0;
      M_reg <= 0;
      N_reg <= 0;
    end
    else begin
      K_reg <= in_valid ? K : K_reg;
      M_reg <= in_valid ? M : M_reg;
      N_reg <= in_valid ? N : N_reg;
    end
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      k_times <= 0;
      m_times <= 0;
      n_times <= 0;
    end
    else begin
      if (in_valid) begin
          k_times <= K + 14;
          m_times <= M[3:0] == 4'h0 ? (M[10:4] - 1) : M[10:4];
          n_times <= N[3:0] == 4'h0 ? (N[ 8:4] - 1) : N[ 8:4];
      end
      else begin
          k_times <= k_times;
          m_times <= m_times;
          n_times <= n_times;
      end
    end
  end

  // ========== SRAM interface ==========
  // Buffer A
  assign A_wr_en = 0;
  assign A_data_in = 0;
  
  // Buffer B
  assign B_wr_en = 0;
  assign B_data_in = 0;
  
  // Buffer C
  assign write_valid = {(r0_done & out_valid[15]), (r1_done & out_valid[14]), (r2_done & out_valid[13]), (r3_done & out_valid[12]), (r4_done & out_valid[11]), (r5_done & out_valid[10]), (r6_done & out_valid[9]), (r7_done & out_valid[8]), (r8_done & out_valid[7]), (r9_done & out_valid[6]), (r10_done & out_valid[5]), (r11_done & out_valid[4]), (r12_done & out_valid[3]), (r13_done & out_valid[2]), (r14_done & out_valid[1]), (r15_done & out_valid[0])};
  assign C_wr_en = |write_valid;
  assign C_index = |write_valid ? idx_c : 0;
  assign C_data_in = data_write;
  
  always @(*) begin
    if (write_valid[15]) 
      data_write = result0;
    else if (write_valid[14]) 
      data_write = result1;
    else if (write_valid[13]) 
      data_write = result2;
    else if (write_valid[12]) 
      data_write = result3;
    else if (write_valid[11]) 
      data_write = result4;
    else if (write_valid[10]) 
      data_write = result5;
    else if (write_valid[9]) 
      data_write = result6;
    else if (write_valid[8]) 
      data_write = result7;
    else if (write_valid[7]) 
      data_write = result8;
    else if (write_valid[6]) 
      data_write = result9;
    else if (write_valid[5]) 
      data_write = result10;
    else if (write_valid[4]) 
      data_write = result11;
    else if (write_valid[3]) 
      data_write = result12;
    else if (write_valid[2]) 
      data_write = result13;
    else if (write_valid[1]) 
      data_write = result14;
    else if (write_valid[0]) 
      data_write = result15;
    else data_write = 'd0;
  end

  // ========== Design ==========
  assign eq_k = cnt_k == k_times;
  assign eq_m = cnt_m == m_times;
  assign eq_n = cnt_n == n_times;
  assign end_feeding = eq_k & eq_m & eq_n;
  assign end_calculating = idx_c == M_reg * (n_times + 1);
  
  always @(*) begin
    if (state == FEED) 
      grabbing = cnt_k < K_reg;
    else 
      grabbing = 0;
  end
  
  always @(posedge clk) begin
    if (!rst_n) begin
      cnt_k <= 0;
      cnt_m <= 0;
      cnt_n <= 0;
      A_index <= 0;
      B_index <= 0;
    end
    else begin
    if (in_valid) begin
      cnt_k <= 0;
      cnt_m <= 0;
      cnt_n <= 0;
      A_index <= 0;
      B_index <= 0;
    end
    else if (eq_k & eq_m & eq_n) begin
      cnt_k <= cnt_k;
      cnt_m <= cnt_m;
      cnt_n <= cnt_n;
      A_index <= A_index;
      B_index <= B_index;
    end
    else if (eq_k & eq_m) begin
      cnt_k <= 0;
      cnt_m <= 0;
      cnt_n <= cnt_n + 1;
      A_index <= 0;
      B_index <= B_index + 1;
    end
    else if (eq_k) begin
      cnt_k <= 0;
      cnt_m <= cnt_m + 1;
      cnt_n <= cnt_n;
      A_index <= A_index + 1;
      B_index <= B_index - (K_reg - 1);
    end
    else begin
      cnt_k <= cnt_k + 1;
      cnt_m <= cnt_m;
      cnt_n <= cnt_n;
      A_index <= cnt_k < K_reg-1 ? A_index + 1 : A_index;
      B_index <= cnt_k < K_reg-1 ? B_index + 1 : B_index;
    end
    end
  end
  
  always @(*) begin
    cal_rst = cnt_k == 0 ? 1 : 0;

    valid0 = (m0 < M_reg) ? 1 : 0;
    valid1 = (m1 < M_reg) ? 1 : 0;
    valid2 = (m2 < M_reg) ? 1 : 0;
    valid3 = (m3 < M_reg) ? 1 : 0;
    valid4 = (m4 < M_reg) ? 1 : 0;
    valid5 = (m5 < M_reg) ? 1 : 0;
    valid6 = (m6 < M_reg) ? 1 : 0;
    valid7 = (m7 < M_reg) ? 1 : 0;
    valid8 = (m8 < M_reg) ? 1 : 0;
    valid9 = (m9 < M_reg) ? 1 : 0;
    valid10= (m10< M_reg) ? 1 : 0;
    valid11= (m11< M_reg) ? 1 : 0;
    valid12= (m12< M_reg) ? 1 : 0;
    valid13= (m13< M_reg) ? 1 : 0;
    valid14= (m14< M_reg) ? 1 : 0;
    valid15= (m15< M_reg) ? 1 : 0;
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      valid1_ff0 <= 0;  valid2_ff0 <= 0;   valid3_ff0 <= 0;  valid4_ff0 <= 0;  valid5_ff0 <= 0;  valid6_ff0 <= 0;  valid7_ff0 <= 0;  valid8_ff0 <= 0;  valid9_ff0 <= 0;  valid10_ff0 <= 0; valid11_ff0 <= 0; valid12_ff0 <= 0; valid13_ff0 <= 0; valid14_ff0 <= 0; valid15_ff0 <= 0;
      valid2_ff1 <= 0;  valid3_ff1 <= 0;   valid4_ff1 <= 0;  valid5_ff1 <= 0;  valid6_ff1 <= 0;  valid7_ff1 <= 0;  valid8_ff1 <= 0;  valid9_ff1 <= 0;  valid10_ff1 <= 0; valid11_ff1 <= 0; valid12_ff1 <= 0; valid13_ff1 <= 0; valid14_ff1 <= 0; valid15_ff1 <= 0;
      valid3_ff2 <= 0;  valid4_ff2 <= 0;   valid5_ff2 <= 0;  valid6_ff2 <= 0;  valid7_ff2 <= 0;  valid8_ff2 <= 0;  valid9_ff2 <= 0;  valid10_ff2 <= 0; valid11_ff2 <= 0; valid12_ff2 <= 0; valid13_ff2 <= 0; valid14_ff2 <= 0; valid15_ff2 <= 0;
      valid4_ff3 <= 0;  valid5_ff3 <= 0;   valid6_ff3 <= 0;  valid7_ff3 <= 0;  valid8_ff3 <= 0;  valid9_ff3 <= 0;  valid10_ff3 <= 0; valid11_ff3 <= 0; valid12_ff3 <= 0; valid13_ff3 <= 0; valid14_ff3 <= 0; valid15_ff3 <= 0;
      valid5_ff4 <= 0;  valid6_ff4 <= 0;   valid7_ff4 <= 0;  valid8_ff4 <= 0;  valid9_ff4 <= 0;  valid10_ff4 <= 0; valid11_ff4 <= 0; valid12_ff4 <= 0; valid13_ff4 <= 0; valid14_ff4 <= 0; valid15_ff4 <= 0;
      valid6_ff5 <= 0;  valid7_ff5 <= 0;   valid8_ff5 <= 0;  valid9_ff5 <= 0;  valid10_ff5 <= 0; valid11_ff5 <= 0; valid12_ff5 <= 0; valid13_ff5 <= 0; valid14_ff5 <= 0; valid15_ff5 <= 0;
      valid7_ff6 <= 0;  valid8_ff6 <= 0;   valid9_ff6 <= 0;  valid10_ff6 <= 0; valid11_ff6 <= 0; valid12_ff6 <= 0; valid13_ff6 <= 0; valid14_ff6 <= 0; valid15_ff6 <= 0;
      valid8_ff7 <= 0;  valid9_ff7 <= 0;   valid10_ff7 <= 0; valid11_ff7 <= 0; valid12_ff7 <= 0; valid13_ff7 <= 0; valid14_ff7 <= 0; valid15_ff7 <= 0;
      valid9_ff8 <= 0;  valid10_ff8 <= 0;  valid11_ff8 <= 0; valid12_ff8 <= 0; valid13_ff8 <= 0; valid14_ff8 <= 0; valid15_ff8 <= 0;
      valid10_ff9 <= 0; valid11_ff9 <= 0;  valid12_ff9 <= 0; valid13_ff9 <= 0; valid14_ff9 <= 0; valid15_ff9 <= 0;
      valid11_ff10<= 0; valid12_ff10<= 0;  valid13_ff10<= 0; valid14_ff10<= 0; valid15_ff10<= 0;
      valid12_ff11<= 0; valid13_ff11<= 0;  valid14_ff11<= 0; valid15_ff11<= 0;
      valid13_ff12<= 0; valid14_ff12<= 0;  valid15_ff12<= 0;
      valid14_ff13<= 0; valid15_ff13<= 0;
      valid15_ff14<= 0;
    end
    else begin
      valid1_ff0 <= valid1;        valid2_ff0 <= valid2;        valid3_ff0 <= valid3;        valid4_ff0 <= valid4;       valid5_ff0 <= valid5;       valid6_ff0 <= valid6;       valid7_ff0 <= valid7;       valid8_ff0 <= valid8;       valid9_ff0 <= valid9;       valid10_ff0 <= valid10;     valid11_ff0 <= valid11;     valid12_ff0 <= valid12;     valid13_ff0 <= valid13;     valid14_ff0 <= valid14;     valid15_ff0 <= valid15;
      valid2_ff1 <= valid2_ff0;    valid3_ff1 <= valid3_ff0;    valid4_ff1 <= valid4_ff0;    valid5_ff1 <= valid5_ff0;   valid6_ff1 <= valid6_ff0;   valid7_ff1 <= valid7_ff0;   valid8_ff1 <= valid8_ff0;   valid9_ff1 <= valid9_ff0;   valid10_ff1 <= valid10_ff0; valid11_ff1 <= valid11_ff0; valid12_ff1 <= valid12_ff0; valid13_ff1 <= valid13_ff0; valid14_ff1 <= valid14_ff0; valid15_ff1 <= valid15_ff0;
      valid3_ff2 <= valid3_ff1;    valid4_ff2 <= valid4_ff1;    valid5_ff2 <= valid5_ff1;    valid6_ff2 <= valid6_ff1;   valid7_ff2 <= valid7_ff1;   valid8_ff2 <= valid8_ff1;   valid9_ff2 <= valid9_ff1;   valid10_ff2 <= valid10_ff1; valid11_ff2 <= valid11_ff1; valid12_ff2 <= valid12_ff1; valid13_ff2 <= valid13_ff1; valid14_ff2 <= valid14_ff1; valid15_ff2 <= valid15_ff1;
      valid4_ff3 <= valid4_ff2;    valid5_ff3 <= valid5_ff2;    valid6_ff3 <= valid6_ff2;    valid7_ff3 <= valid7_ff2;   valid8_ff3 <= valid8_ff2;   valid9_ff3 <= valid9_ff2;   valid10_ff3 <= valid10_ff2; valid11_ff3 <= valid11_ff2; valid12_ff3 <= valid12_ff2; valid13_ff3 <= valid13_ff2; valid14_ff3 <= valid14_ff2; valid15_ff3 <= valid15_ff2;
      valid5_ff4 <= valid5_ff3;    valid6_ff4 <= valid6_ff3;    valid7_ff4 <= valid7_ff3;    valid8_ff4 <= valid8_ff3;   valid9_ff4 <= valid9_ff3;   valid10_ff4 <= valid10_ff3; valid11_ff4 <= valid11_ff3; valid12_ff4 <= valid12_ff3; valid13_ff4 <= valid13_ff3; valid14_ff4 <= valid14_ff3; valid15_ff4 <= valid15_ff3;
      valid6_ff5 <= valid6_ff4;    valid7_ff5 <= valid7_ff4;    valid8_ff5 <= valid8_ff4;    valid9_ff5 <= valid9_ff4;   valid10_ff5 <= valid10_ff4; valid11_ff5 <= valid11_ff4; valid12_ff5 <= valid12_ff4; valid13_ff5 <= valid13_ff4; valid14_ff5 <= valid14_ff4; valid15_ff5 <= valid15_ff4;
      valid7_ff6 <= valid7_ff5;    valid8_ff6 <= valid8_ff5;    valid9_ff6 <= valid9_ff5;    valid10_ff6 <= valid10_ff5; valid11_ff6 <= valid11_ff5; valid12_ff6 <= valid12_ff5; valid13_ff6 <= valid13_ff5; valid14_ff6 <= valid14_ff5; valid15_ff6 <= valid15_ff5;
      valid8_ff7 <= valid8_ff6;    valid9_ff7 <= valid9_ff6;    valid10_ff7 <= valid10_ff6;  valid11_ff7 <= valid11_ff6; valid12_ff7 <= valid12_ff6; valid13_ff7 <= valid13_ff6; valid14_ff7 <= valid14_ff6; valid15_ff7 <= valid15_ff6;
      valid9_ff8 <= valid9_ff7;    valid10_ff8 <= valid10_ff7;  valid11_ff8 <= valid11_ff7;  valid12_ff8 <= valid12_ff7; valid13_ff8 <= valid13_ff7; valid14_ff8 <= valid14_ff7; valid15_ff8 <= valid15_ff7;
      valid10_ff9 <= valid10_ff8;  valid11_ff9 <= valid11_ff8;  valid12_ff9 <= valid12_ff8;  valid13_ff9 <= valid13_ff8; valid14_ff9 <= valid14_ff8; valid15_ff9 <= valid15_ff8;
      valid11_ff10<= valid11_ff9;  valid12_ff10<= valid12_ff9;  valid13_ff10<= valid13_ff9;  valid14_ff10<= valid14_ff9; valid15_ff10<= valid15_ff9;
      valid12_ff11<= valid12_ff10; valid13_ff11<= valid13_ff10; valid14_ff11<= valid14_ff10; valid15_ff11<= valid15_ff10;
      valid13_ff12<= valid13_ff11; valid14_ff12<= valid14_ff11; valid15_ff12<= valid15_ff11;
      valid14_ff13<= valid14_ff12; valid15_ff13<= valid15_ff12;
      valid15_ff14<= valid15_ff13;
    end
  end

  always @(*) begin
    row0 = grabbing ? A_data_out[127:120] : 0;
    row1 = grabbing ? A_data_out[119:112] : 0;
    row2 = grabbing ? A_data_out[111:104] : 0;
    row3 = grabbing ? A_data_out[103:96] : 0;
    row4 = grabbing ? A_data_out[95:88] : 0;
    row5 = grabbing ? A_data_out[87:80] : 0;
    row6 = grabbing ? A_data_out[79:72] : 0;
    row7 = grabbing ? A_data_out[71:64] : 0;
    row8 = grabbing ? A_data_out[63:56] : 0;
    row9 = grabbing ? A_data_out[55:48] : 0;
    row10= grabbing ? A_data_out[47:40] : 0;
    row11= grabbing ? A_data_out[39:32] : 0;
    row12= grabbing ? A_data_out[31:24] : 0;
    row13= grabbing ? A_data_out[23:16] : 0;
    row14= grabbing ? A_data_out[15: 8] : 0;
    row15= grabbing ? A_data_out[ 7: 0] : 0;
  
    col0 = grabbing ? B_data_out[127:120] : 0;
    col1 = grabbing ? B_data_out[119:112] : 0;
    col2 = grabbing ? B_data_out[111:104] : 0;
    col3 = grabbing ? B_data_out[103:96] : 0;
    col4 = grabbing ? B_data_out[95:88] : 0;
    col5 = grabbing ? B_data_out[87:80] : 0;
    col6 = grabbing ? B_data_out[79:72] : 0;
    col7 = grabbing ? B_data_out[71:64] : 0;
    col8 = grabbing ? B_data_out[63:56] : 0;
    col9 = grabbing ? B_data_out[55:48] : 0;
    col10= grabbing ? B_data_out[47:40] : 0;
    col11= grabbing ? B_data_out[39:32] : 0;
    col12= grabbing ? B_data_out[31:24] : 0;
    col13= grabbing ? B_data_out[23:16] : 0;
    col14= grabbing ? B_data_out[15: 8] : 0;
    col15= grabbing ? B_data_out[ 7: 0] : 0;
  end
  
  always @(posedge clk) begin
    if (!rst_n) begin
      row1_ff0 <= 0;  row2_ff0 <= 0;  row3_ff0 <= 0;  row4_ff0 <= 0;  row5_ff0 <= 0;  row6_ff0 <= 0;  row7_ff0 <= 0;  row8_ff0 <= 0;  row9_ff0 <= 0;  row10_ff0 <= 0; row11_ff0 <= 0; row12_ff0 <= 0; row13_ff0 <= 0; row14_ff0 <= 0; row15_ff0 <= 0;
      row2_ff1 <= 0;  row3_ff1 <= 0;  row4_ff1 <= 0;  row5_ff1 <= 0;  row6_ff1 <= 0;  row7_ff1 <= 0;  row8_ff1 <= 0;  row9_ff1 <= 0;  row10_ff1 <= 0; row11_ff1 <= 0; row12_ff1 <= 0; row13_ff1 <= 0; row14_ff1 <= 0; row15_ff1 <= 0;
      row3_ff2 <= 0;  row4_ff2 <= 0;  row5_ff2 <= 0;  row6_ff2 <= 0;  row7_ff2 <= 0;  row8_ff2 <= 0;  row9_ff2 <= 0;  row10_ff2 <= 0; row11_ff2 <= 0; row12_ff2 <= 0; row13_ff2 <= 0; row14_ff2 <= 0; row15_ff2 <= 0;
      row4_ff3 <= 0;  row5_ff3 <= 0;  row6_ff3 <= 0;  row7_ff3 <= 0;  row8_ff3 <= 0;  row9_ff3 <= 0;  row10_ff3 <= 0; row11_ff3 <= 0; row12_ff3 <= 0; row13_ff3 <= 0; row14_ff3 <= 0; row15_ff3 <= 0;
      row5_ff4 <= 0;  row6_ff4 <= 0;  row7_ff4 <= 0;  row8_ff4 <= 0;  row9_ff4 <= 0;  row10_ff4 <= 0; row11_ff4 <= 0; row12_ff4 <= 0; row13_ff4 <= 0; row14_ff4 <= 0; row15_ff4 <= 0;
      row6_ff5 <= 0;  row7_ff5 <= 0;  row8_ff5 <= 0;  row9_ff5 <= 0;  row10_ff5 <= 0; row11_ff5 <= 0; row12_ff5 <= 0; row13_ff5 <= 0; row14_ff5 <= 0; row15_ff5 <= 0;
      row7_ff6 <= 0;  row8_ff6 <= 0;  row9_ff6 <= 0;  row10_ff6 <= 0; row11_ff6 <= 0; row12_ff6 <= 0; row13_ff6 <= 0; row14_ff6 <= 0; row15_ff6 <= 0;
      row8_ff7 <= 0;  row9_ff7 <= 0;  row10_ff7 <= 0; row11_ff7 <= 0; row12_ff7 <= 0; row13_ff7 <= 0; row14_ff7 <= 0; row15_ff7 <= 0;
      row9_ff8 <= 0;  row10_ff8 <= 0; row11_ff8 <= 0; row12_ff8 <= 0; row13_ff8 <= 0; row14_ff8 <= 0; row15_ff8 <= 0;
      row10_ff9 <= 0; row11_ff9 <= 0; row12_ff9 <= 0; row13_ff9 <= 0; row14_ff9 <= 0; row15_ff9 <= 0;
      row11_ff10<= 0; row12_ff10<= 0; row13_ff10<= 0; row14_ff10<= 0; row15_ff10<= 0;
      row12_ff11<= 0; row13_ff11<= 0; row14_ff11<= 0; row15_ff11<= 0;
      row13_ff12<= 0; row14_ff12<= 0; row15_ff12<= 0;
      row14_ff13<= 0; row15_ff13<= 0;
      row15_ff14<= 0;
  
      col1_ff0 <= 0;  col2_ff0 <= 0;  col3_ff0 <= 0;  col4_ff0 <= 0;  col5_ff0 <= 0;  col6_ff0 <= 0;  col7_ff0 <= 0;  col8_ff0 <= 0;  col9_ff0 <= 0;  col10_ff0 <= 0; col11_ff0 <= 0; col12_ff0 <= 0; col13_ff0 <= 0; col14_ff0 <= 0; col15_ff0 <= 0;
      col2_ff1 <= 0;  col3_ff1 <= 0;  col4_ff1 <= 0;  col5_ff1 <= 0;  col6_ff1 <= 0;  col7_ff1 <= 0;  col8_ff1 <= 0;  col9_ff1 <= 0;  col10_ff1 <= 0; col11_ff1 <= 0; col12_ff1 <= 0; col13_ff1 <= 0; col14_ff1 <= 0; col15_ff1 <= 0;
      col3_ff2 <= 0;  col4_ff2 <= 0;  col5_ff2 <= 0;  col6_ff2 <= 0;  col7_ff2 <= 0;  col8_ff2 <= 0;  col9_ff2 <= 0;  col10_ff2 <= 0; col11_ff2 <= 0; col12_ff2 <= 0; col13_ff2 <= 0; col14_ff2 <= 0; col15_ff2 <= 0;
      col4_ff3 <= 0;  col5_ff3 <= 0;  col6_ff3 <= 0;  col7_ff3 <= 0;  col8_ff3 <= 0;  col9_ff3 <= 0;  col10_ff3 <= 0; col11_ff3 <= 0; col12_ff3 <= 0; col13_ff3 <= 0; col14_ff3 <= 0; col15_ff3 <= 0;
      col5_ff4 <= 0;  col6_ff4 <= 0;  col7_ff4 <= 0;  col8_ff4 <= 0;  col9_ff4 <= 0;  col10_ff4 <= 0; col11_ff4 <= 0; col12_ff4 <= 0; col13_ff4 <= 0; col14_ff4 <= 0; col15_ff4 <= 0;
      col6_ff5 <= 0;  col7_ff5 <= 0;  col8_ff5 <= 0;  col9_ff5 <= 0;  col10_ff5 <= 0; col11_ff5 <= 0; col12_ff5 <= 0; col13_ff5 <= 0; col14_ff5 <= 0; col15_ff5 <= 0;
      col7_ff6 <= 0;  col8_ff6 <= 0;  col9_ff6 <= 0;  col10_ff6 <= 0; col11_ff6 <= 0; col12_ff6 <= 0; col13_ff6 <= 0; col14_ff6 <= 0; col15_ff6 <= 0;
      col8_ff7 <= 0;  col9_ff7 <= 0;  col10_ff7 <= 0; col11_ff7 <= 0; col12_ff7 <= 0; col13_ff7 <= 0; col14_ff7 <= 0; col15_ff7 <= 0;
      col9_ff8 <= 0;  col10_ff8 <= 0; col11_ff8 <= 0; col12_ff8 <= 0; col13_ff8 <= 0; col14_ff8 <= 0; col15_ff8 <= 0;
      col10_ff9 <= 0; col11_ff9 <= 0; col12_ff9 <= 0; col13_ff9 <= 0; col14_ff9 <= 0; col15_ff9 <= 0;
      col11_ff10<= 0; col12_ff10<= 0; col13_ff10<= 0; col14_ff10<= 0; col15_ff10<= 0;
      col12_ff11<= 0; col13_ff11<= 0; col14_ff11<= 0; col15_ff11<= 0;
      col13_ff12<= 0; col14_ff12<= 0; col15_ff12<= 0;
      col14_ff13<= 0; col15_ff13<= 0;
      col15_ff14<= 0;
    end
    else begin
      row1_ff0 <= row1;        row2_ff0 <= row2;        row3_ff0 <= row3;        row4_ff0 <= row4;       row5_ff0 <= row5;       row6_ff0 <= row6;       row7_ff0 <= row7;       row8_ff0 <= row8;       row9_ff0 <= row9;       row10_ff0 <= row10;     row11_ff0 <= row11;     row12_ff0 <= row12;     row13_ff0 <= row13;     row14_ff0 <= row14;     row15_ff0 <= row15;
      row2_ff1 <= row2_ff0;    row3_ff1 <= row3_ff0;    row4_ff1 <= row4_ff0;    row5_ff1 <= row5_ff0;   row6_ff1 <= row6_ff0;   row7_ff1 <= row7_ff0;   row8_ff1 <= row8_ff0;   row9_ff1 <= row9_ff0;   row10_ff1 <= row10_ff0; row11_ff1 <= row11_ff0; row12_ff1 <= row12_ff0; row13_ff1 <= row13_ff0; row14_ff1 <= row14_ff0; row15_ff1 <= row15_ff0;
      row3_ff2 <= row3_ff1;    row4_ff2 <= row4_ff1;    row5_ff2 <= row5_ff1;    row6_ff2 <= row6_ff1;   row7_ff2 <= row7_ff1;   row8_ff2 <= row8_ff1;   row9_ff2 <= row9_ff1;   row10_ff2 <= row10_ff1; row11_ff2 <= row11_ff1; row12_ff2 <= row12_ff1; row13_ff2 <= row13_ff1; row14_ff2 <= row14_ff1; row15_ff2 <= row15_ff1;
      row4_ff3 <= row4_ff2;    row5_ff3 <= row5_ff2;    row6_ff3 <= row6_ff2;    row7_ff3 <= row7_ff2;   row8_ff3 <= row8_ff2;   row9_ff3 <= row9_ff2;   row10_ff3 <= row10_ff2; row11_ff3 <= row11_ff2; row12_ff3 <= row12_ff2; row13_ff3 <= row13_ff2; row14_ff3 <= row14_ff2; row15_ff3 <= row15_ff2;
      row5_ff4 <= row5_ff3;    row6_ff4 <= row6_ff3;    row7_ff4 <= row7_ff3;    row8_ff4 <= row8_ff3;   row9_ff4 <= row9_ff3;   row10_ff4 <= row10_ff3; row11_ff4 <= row11_ff3; row12_ff4 <= row12_ff3; row13_ff4 <= row13_ff3; row14_ff4 <= row14_ff3; row15_ff4 <= row15_ff3;
      row6_ff5 <= row6_ff4;    row7_ff5 <= row7_ff4;    row8_ff5 <= row8_ff4;    row9_ff5 <= row9_ff4;   row10_ff5 <= row10_ff4; row11_ff5 <= row11_ff4; row12_ff5 <= row12_ff4; row13_ff5 <= row13_ff4; row14_ff5 <= row14_ff4; row15_ff5 <= row15_ff4;
      row7_ff6 <= row7_ff5;    row8_ff6 <= row8_ff5;    row9_ff6 <= row9_ff5;    row10_ff6 <= row10_ff5; row11_ff6 <= row11_ff5; row12_ff6 <= row12_ff5; row13_ff6 <= row13_ff5; row14_ff6 <= row14_ff5; row15_ff6 <= row15_ff5;
      row8_ff7 <= row8_ff6;    row9_ff7 <= row9_ff6;    row10_ff7 <= row10_ff6;  row11_ff7 <= row11_ff6; row12_ff7 <= row12_ff6; row13_ff7 <= row13_ff6; row14_ff7 <= row14_ff6; row15_ff7 <= row15_ff6;
      row9_ff8 <= row9_ff7;    row10_ff8 <= row10_ff7;  row11_ff8 <= row11_ff7;  row12_ff8 <= row12_ff7; row13_ff8 <= row13_ff7; row14_ff8 <= row14_ff7; row15_ff8 <= row15_ff7;
      row10_ff9 <= row10_ff8;  row11_ff9 <= row11_ff8;  row12_ff9 <= row12_ff8;  row13_ff9 <= row13_ff8; row14_ff9 <= row14_ff8; row15_ff9 <= row15_ff8;
      row11_ff10<= row11_ff9;  row12_ff10<= row12_ff9;  row13_ff10<= row13_ff9;  row14_ff10<= row14_ff9; row15_ff10<= row15_ff9;
      row12_ff11<= row12_ff10; row13_ff11<= row13_ff10; row14_ff11<= row14_ff10; row15_ff11<= row15_ff10;
      row13_ff12<= row13_ff11; row14_ff12<= row14_ff11; row15_ff12<= row15_ff11;
      row14_ff13<= row14_ff12; row15_ff13<= row15_ff12;
      row15_ff14<= row15_ff13;
  
      col1_ff0 <= col1;        col2_ff0 <= col2;        col3_ff0 <= col3;        col4_ff0 <= col4;       col5_ff0 <= col5;       col6_ff0 <= col6;       col7_ff0 <= col7;       col8_ff0 <= col8;       col9_ff0 <= col9;       col10_ff0 <= col10;     col11_ff0 <= col11;     col12_ff0 <= col12;     col13_ff0 <= col13;     col14_ff0 <= col14;     col15_ff0 <= col15;
      col2_ff1 <= col2_ff0;    col3_ff1 <= col3_ff0;    col4_ff1 <= col4_ff0;    col5_ff1 <= col5_ff0;   col6_ff1 <= col6_ff0;   col7_ff1 <= col7_ff0;   col8_ff1 <= col8_ff0;   col9_ff1 <= col9_ff0;   col10_ff1 <= col10_ff0; col11_ff1 <= col11_ff0; col12_ff1 <= col12_ff0; col13_ff1 <= col13_ff0; col14_ff1 <= col14_ff0; col15_ff1 <= col15_ff0;
      col3_ff2 <= col3_ff1;    col4_ff2 <= col4_ff1;    col5_ff2 <= col5_ff1;    col6_ff2 <= col6_ff1;   col7_ff2 <= col7_ff1;   col8_ff2 <= col8_ff1;   col9_ff2 <= col9_ff1;   col10_ff2 <= col10_ff1; col11_ff2 <= col11_ff1; col12_ff2 <= col12_ff1; col13_ff2 <= col13_ff1; col14_ff2 <= col14_ff1; col15_ff2 <= col15_ff1;
      col4_ff3 <= col4_ff2;    col5_ff3 <= col5_ff2;    col6_ff3 <= col6_ff2;    col7_ff3 <= col7_ff2;   col8_ff3 <= col8_ff2;   col9_ff3 <= col9_ff2;   col10_ff3 <= col10_ff2; col11_ff3 <= col11_ff2; col12_ff3 <= col12_ff2; col13_ff3 <= col13_ff2; col14_ff3 <= col14_ff2; col15_ff3 <= col15_ff2;
      col5_ff4 <= col5_ff3;    col6_ff4 <= col6_ff3;    col7_ff4 <= col7_ff3;    col8_ff4 <= col8_ff3;   col9_ff4 <= col9_ff3;   col10_ff4 <= col10_ff3; col11_ff4 <= col11_ff3; col12_ff4 <= col12_ff3; col13_ff4 <= col13_ff3; col14_ff4 <= col14_ff3; col15_ff4 <= col15_ff3;
      col6_ff5 <= col6_ff4;    col7_ff5 <= col7_ff4;    col8_ff5 <= col8_ff4;    col9_ff5 <= col9_ff4;   col10_ff5 <= col10_ff4; col11_ff5 <= col11_ff4; col12_ff5 <= col12_ff4; col13_ff5 <= col13_ff4; col14_ff5 <= col14_ff4; col15_ff5 <= col15_ff4;
      col7_ff6 <= col7_ff5;    col8_ff6 <= col8_ff5;    col9_ff6 <= col9_ff5;    col10_ff6 <= col10_ff5; col11_ff6 <= col11_ff5; col12_ff6 <= col12_ff5; col13_ff6 <= col13_ff5; col14_ff6 <= col14_ff5; col15_ff6 <= col15_ff5;
      col8_ff7 <= col8_ff6;    col9_ff7 <= col9_ff6;    col10_ff7 <= col10_ff6;  col11_ff7 <= col11_ff6; col12_ff7 <= col12_ff6; col13_ff7 <= col13_ff6; col14_ff7 <= col14_ff6; col15_ff7 <= col15_ff6;
      col9_ff8 <= col9_ff7;    col10_ff8 <= col10_ff7;  col11_ff8 <= col11_ff7;  col12_ff8 <= col12_ff7; col13_ff8 <= col13_ff7; col14_ff8 <= col14_ff7; col15_ff8 <= col15_ff7;
      col10_ff9 <= col10_ff8;  col11_ff9 <= col11_ff8;  col12_ff9 <= col12_ff8;  col13_ff9 <= col13_ff8; col14_ff9 <= col14_ff8; col15_ff9 <= col15_ff8;
      col11_ff10<= col11_ff9;  col12_ff10<= col12_ff9;  col13_ff10<= col13_ff9;  col14_ff10<= col14_ff9; col15_ff10<= col15_ff9;
      col12_ff11<= col12_ff10; col13_ff11<= col13_ff10; col14_ff11<= col14_ff10; col15_ff11<= col15_ff10;
      col13_ff12<= col13_ff11; col14_ff12<= col14_ff11; col15_ff12<= col15_ff11;
      col14_ff13<= col14_ff12; col15_ff13<= col15_ff12;
      col15_ff14<= col15_ff13;
    end
  end
  
  always @(*) begin
    a_bus = {row0, row1_ff0, row2_ff1, row3_ff2, row4_ff3, row5_ff4, row6_ff5, row7_ff6, row8_ff7, row9_ff8, row10_ff9, row11_ff10, row12_ff11, row13_ff12, row14_ff13, row15_ff14};
    b_bus = {col0, col1_ff0, col2_ff1, col3_ff2, col4_ff3, col5_ff4, col6_ff5, col7_ff6, col8_ff7, col9_ff8, col10_ff9, col11_ff10, col12_ff11, col13_ff12, col14_ff13, col15_ff14};
    valid_bus = {valid0, valid1_ff0, valid2_ff1, valid3_ff2, valid4_ff3, valid5_ff4, valid6_ff5, valid7_ff6, valid8_ff7, valid9_ff8, valid10_ff9, valid11_ff10, valid12_ff11, valid13_ff12, valid14_ff13, valid15_ff14};
  end


  Systolic_array_16 sys_array_16_inst ( 
    .clk(clk), 
    .rst_n(rst_n), 
    .in_valid(valid_bus), 
    .offset_valid(1'b1), 
    .sys_rst_seq0(cal_rst),   
    .left(a_bus), 
    .top(b_bus), 
    .out_valid(out_valid), 
    .row0_out(result0), 
    .row1_out(result1), 
    .row2_out(result2), 
    .row3_out(result3), 
    .row4_out(result4), 
    .row5_out(result5), 
    .row6_out(result6), 
    .row7_out(result7), 
    .row8_out(result8), 
    .row9_out(result9), 
    .row10_out(result10), 
    .row11_out(result11), 
    .row12_out(result12), 
    .row13_out(result13), 
    .row14_out(result14), 
    .row15_out(result15)
  );


  always @(posedge clk) begin
    if (!rst_n) begin
      eq_k_ff0 <= 0;
      r0_done <= 0;
      r1_done <= 0;
      r2_done <= 0;
      r3_done <= 0;
      r4_done <= 0;
      r5_done <= 0;
      r6_done <= 0;
      r7_done <= 0;
      r8_done <= 0;
      r9_done <= 0;
      r10_done <= 0;
      r11_done <= 0;
      r12_done <= 0;
      r13_done <= 0;
      r14_done <= 0;
      r15_done <= 0;
    end
    else begin
        eq_k_ff0 <= state == FEED ? eq_k : 0;

        r0_done <= in_valid ? 0 : eq_k_ff0;
        r1_done <= in_valid ? 0 : r0_done;
        r2_done <= in_valid ? 0 : r1_done;
        r3_done <= in_valid ? 0 : r2_done;
        r4_done <= in_valid ? 0 : r3_done;
        r5_done <= in_valid ? 0 : r4_done;
        r6_done <= in_valid ? 0 : r5_done;
        r7_done <= in_valid ? 0 : r6_done;
        r8_done <= in_valid ? 0 : r7_done;
        r9_done <= in_valid ? 0 : r8_done;
        r10_done <= in_valid ? 0 : r9_done;
        r11_done <= in_valid ? 0 : r10_done;
        r12_done <= in_valid ? 0 : r11_done;
        r13_done <= in_valid ? 0 : r12_done;
        r14_done <= in_valid ? 0 : r13_done;
        r15_done <= in_valid ? 0 : r14_done;
    end
  end

  always @(posedge clk) begin
    if (!rst_n) 
      idx_c <= 0;
    else begin
      if (in_valid) 
        idx_c <= 0;
      else if (|write_valid) 
        idx_c <= idx_c + 1;
      else 
        idx_c <= idx_c;
    end
  end

  always @(posedge clk) begin
    if (!rst_n) 
      busy <= 0;
    else 
      busy <= in_valid ? 1 : (end_calculating ? 0 : busy);
  end
endmodule

// 16x16
module Systolic_array_16(
    clk,
    rst_n,
    in_valid,
    offset_valid,
    sys_rst_seq0,
    left,
    top,
    out_valid,
    row0_out,
    row1_out,
    row2_out,
    row3_out,
    row4_out,
    row5_out,
    row6_out,
    row7_out,
    row8_out,
    row9_out,
    row10_out,
    row11_out,
    row12_out,
    row13_out,
    row14_out,
    row15_out
);

  input clk, rst_n;
  input [15:0] in_valid;
  input offset_valid;
  input sys_rst_seq0;
  input [127:0] left, top;
  output reg [15:0] out_valid;
  output wire [511:0] row0_out, row1_out, row2_out, row3_out, row4_out, row5_out, row6_out, row7_out, row8_out, row9_out, row10_out, row11_out, row12_out, row13_out, row14_out, row15_out;

  wire sys_rst_seq1, sys_rst_seq2, sys_rst_seq3, sys_rst_seq4, sys_rst_seq5, sys_rst_seq6, sys_rst_seq7, sys_rst_seq8, sys_rst_seq9;
  wire sys_rst_seq10, sys_rst_seq11, sys_rst_seq12, sys_rst_seq13, sys_rst_seq14, sys_rst_seq15, sys_rst_seq16, sys_rst_seq17, sys_rst_seq18, sys_rst_seq19;
  wire sys_rst_seq20, sys_rst_seq21, sys_rst_seq22, sys_rst_seq23, sys_rst_seq24, sys_rst_seq25, sys_rst_seq26, sys_rst_seq27, sys_rst_seq28, sys_rst_seq29, sys_rst_seq30, sys_rst_seq31;
  wire [143:0] left_seq0, left_seq1, left_seq2, left_seq3, left_seq4, left_seq5, left_seq6, left_seq7, left_seq8, left_seq9, left_seq10, left_seq11, left_seq12, left_seq13, left_seq14, left_seq15,  right;
  wire [127:0]             top_seq1,  top_seq2,  top_seq3,  top_seq4,  top_seq5,  top_seq6,  top_seq7,  top_seq8,  top_seq9,  top_seq10,  top_seq11,  top_seq12,  top_seq13,  top_seq14,  top_seq15, bottom;
  
  wire signed [8:0] left_offset0 = offset_valid ? $signed(left[127:120]) + 128 : $signed(left[127:120]);
  wire signed [8:0] left_offset1 = offset_valid ? $signed(left[119:112]) + 128 : $signed(left[119:112]);
  wire signed [8:0] left_offset2 = offset_valid ? $signed(left[111:104]) + 128 : $signed(left[111:104]);
  wire signed [8:0] left_offset3 = offset_valid ? $signed(left[103: 96]) + 128 : $signed(left[103: 96]);
  wire signed [8:0] left_offset4 = offset_valid ? $signed(left[ 95: 88]) + 128 : $signed(left[ 95: 88]);
  wire signed [8:0] left_offset5 = offset_valid ? $signed(left[ 87: 80]) + 128 : $signed(left[ 87: 80]);
  wire signed [8:0] left_offset6 = offset_valid ? $signed(left[ 79: 72]) + 128 : $signed(left[ 79: 72]);
  wire signed [8:0] left_offset7 = offset_valid ? $signed(left[ 71: 64]) + 128 : $signed(left[ 71: 64]);
  wire signed [8:0] left_offset8 = offset_valid ? $signed(left[ 63: 56]) + 128 : $signed(left[ 63: 56]);
  wire signed [8:0] left_offset9 = offset_valid ? $signed(left[ 55: 48]) + 128 : $signed(left[ 55: 48]);
  wire signed [8:0] left_offset10= offset_valid ? $signed(left[ 47: 40]) + 128 : $signed(left[ 47: 40]);
  wire signed [8:0] left_offset11= offset_valid ? $signed(left[ 39: 32]) + 128 : $signed(left[ 39: 32]);
  wire signed [8:0] left_offset12= offset_valid ? $signed(left[ 31: 24]) + 128 : $signed(left[ 31: 24]);
  wire signed [8:0] left_offset13= offset_valid ? $signed(left[ 23: 16]) + 128 : $signed(left[ 23: 16]);
  wire signed [8:0] left_offset14= offset_valid ? $signed(left[ 15:  8]) + 128 : $signed(left[ 15:  8]);
  wire signed [8:0] left_offset15= offset_valid ? $signed(left[  7:  0]) + 128 : $signed(left[  7:  0]);
  assign left_seq0 = {left_offset0, left_offset1, left_offset2, left_offset3, left_offset4, left_offset5, left_offset6, left_offset7, left_offset8, left_offset9, left_offset10, left_offset11, left_offset12, left_offset13, left_offset14, left_offset15};
  
  reg [15:0] out_valid_pp0, out_valid_pp1, out_valid_pp2, out_valid_pp3, out_valid_pp4, out_valid_pp5, out_valid_pp6, out_valid_pp7, out_valid_pp8, out_valid_pp9, out_valid_pp10, out_valid_pp11, out_valid_pp12, out_valid_pp13;
  
  wire [31:0] arr_out [0:15][0:15];


  // Signal naming is based on 0-indexing.
  PE pe_0_0  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq0 ), .left_in(left_seq0 [143:135]), .top_in(     top [127:120]), .pe_rst_seq(sys_rst_seq1 ), .right_out(left_seq1 [143:135]), .bottom_out(top_seq1 [127:120]), .acc(arr_out[0][0] ));
  PE pe_0_1  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq1 ), .left_in(left_seq1 [143:135]), .top_in(     top [119:112]), .pe_rst_seq(sys_rst_seq2 ), .right_out(left_seq2 [143:135]), .bottom_out(top_seq1 [119:112]), .acc(arr_out[0][1] ));
  PE pe_0_2  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq2 ), .left_in(left_seq2 [143:135]), .top_in(     top [111:104]), .pe_rst_seq(sys_rst_seq3 ), .right_out(left_seq3 [143:135]), .bottom_out(top_seq1 [111:104]), .acc(arr_out[0][2] ));
  PE pe_0_3  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq3 ), .left_in(left_seq3 [143:135]), .top_in(     top [103: 96]), .pe_rst_seq(sys_rst_seq4 ), .right_out(left_seq4 [143:135]), .bottom_out(top_seq1 [103: 96]), .acc(arr_out[0][3] ));
  PE pe_0_4  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq4 ), .left_in(left_seq4 [143:135]), .top_in(     top [ 95: 88]), .pe_rst_seq(sys_rst_seq5 ), .right_out(left_seq5 [143:135]), .bottom_out(top_seq1 [ 95: 88]), .acc(arr_out[0][4] ));
  PE pe_0_5  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq5 ), .left_in(left_seq5 [143:135]), .top_in(     top [ 87: 80]), .pe_rst_seq(sys_rst_seq6 ), .right_out(left_seq6 [143:135]), .bottom_out(top_seq1 [ 87: 80]), .acc(arr_out[0][5] ));
  PE pe_0_6  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq6 ), .left_in(left_seq6 [143:135]), .top_in(     top [ 79: 72]), .pe_rst_seq(sys_rst_seq7 ), .right_out(left_seq7 [143:135]), .bottom_out(top_seq1 [ 79: 72]), .acc(arr_out[0][6] ));
  PE pe_0_7  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq7 ), .left_in(left_seq7 [143:135]), .top_in(     top [ 71: 64]), .pe_rst_seq(sys_rst_seq8 ), .right_out(left_seq8 [143:135]), .bottom_out(top_seq1 [ 71: 64]), .acc(arr_out[0][7] ));
  PE pe_0_8  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq8 ), .left_in(left_seq8 [143:135]), .top_in(     top [ 63: 56]), .pe_rst_seq(sys_rst_seq9 ), .right_out(left_seq9 [143:135]), .bottom_out(top_seq1 [ 63: 56]), .acc(arr_out[0][8] ));
  PE pe_0_9  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq9 ), .left_in(left_seq9 [143:135]), .top_in(     top [ 55: 48]), .pe_rst_seq(sys_rst_seq10), .right_out(left_seq10[143:135]), .bottom_out(top_seq1 [ 55: 48]), .acc(arr_out[0][9] ));
  PE pe_0_10 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq10), .left_in(left_seq10[143:135]), .top_in(     top [ 47: 40]), .pe_rst_seq(sys_rst_seq11), .right_out(left_seq11[143:135]), .bottom_out(top_seq1 [ 47: 40]), .acc(arr_out[0][10]));
  PE pe_0_11 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq11), .left_in(left_seq11[143:135]), .top_in(     top [ 39: 32]), .pe_rst_seq(sys_rst_seq12), .right_out(left_seq12[143:135]), .bottom_out(top_seq1 [ 39: 32]), .acc(arr_out[0][11]));
  PE pe_0_12 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq12), .left_in(left_seq12[143:135]), .top_in(     top [ 31: 24]), .pe_rst_seq(sys_rst_seq13), .right_out(left_seq13[143:135]), .bottom_out(top_seq1 [ 31: 24]), .acc(arr_out[0][12]));
  PE pe_0_13 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq13), .left_in(left_seq13[143:135]), .top_in(     top [ 23: 16]), .pe_rst_seq(sys_rst_seq14), .right_out(left_seq14[143:135]), .bottom_out(top_seq1 [ 23: 16]), .acc(arr_out[0][13]));
  PE pe_0_14 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq14), .left_in(left_seq14[143:135]), .top_in(     top [ 15:  8]), .pe_rst_seq(sys_rst_seq15), .right_out(left_seq15[143:135]), .bottom_out(top_seq1 [ 15:  8]), .acc(arr_out[0][14]));
  PE pe_0_15 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq15[143:135]), .top_in(     top [  7:  0]), .pe_rst_seq(sys_rst_seq16), .right_out(     right[143:135]), .bottom_out(top_seq1 [  7:  0]), .acc(arr_out[0][15]));
  
  PE pe_1_0  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq1 ), .left_in(left_seq0 [134:126]), .top_in(top_seq1 [127:120]), .pe_rst_seq(             ), .right_out(left_seq1 [134:126]), .bottom_out(top_seq2 [127:120]), .acc(arr_out[1][0] ));
  PE pe_1_1  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq2 ), .left_in(left_seq1 [134:126]), .top_in(top_seq1 [119:112]), .pe_rst_seq(             ), .right_out(left_seq2 [134:126]), .bottom_out(top_seq2 [119:112]), .acc(arr_out[1][1] ));
  PE pe_1_2  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq3 ), .left_in(left_seq2 [134:126]), .top_in(top_seq1 [111:104]), .pe_rst_seq(             ), .right_out(left_seq3 [134:126]), .bottom_out(top_seq2 [111:104]), .acc(arr_out[1][2] ));
  PE pe_1_3  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq4 ), .left_in(left_seq3 [134:126]), .top_in(top_seq1 [103: 96]), .pe_rst_seq(             ), .right_out(left_seq4 [134:126]), .bottom_out(top_seq2 [103: 96]), .acc(arr_out[1][3] ));
  PE pe_1_4  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq5 ), .left_in(left_seq4 [134:126]), .top_in(top_seq1 [ 95: 88]), .pe_rst_seq(             ), .right_out(left_seq5 [134:126]), .bottom_out(top_seq2 [ 95: 88]), .acc(arr_out[1][4] ));
  PE pe_1_5  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq6 ), .left_in(left_seq5 [134:126]), .top_in(top_seq1 [ 87: 80]), .pe_rst_seq(             ), .right_out(left_seq6 [134:126]), .bottom_out(top_seq2 [ 87: 80]), .acc(arr_out[1][5] ));
  PE pe_1_6  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq7 ), .left_in(left_seq6 [134:126]), .top_in(top_seq1 [ 79: 72]), .pe_rst_seq(             ), .right_out(left_seq7 [134:126]), .bottom_out(top_seq2 [ 79: 72]), .acc(arr_out[1][6] ));
  PE pe_1_7  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq8 ), .left_in(left_seq7 [134:126]), .top_in(top_seq1 [ 71: 64]), .pe_rst_seq(             ), .right_out(left_seq8 [134:126]), .bottom_out(top_seq2 [ 71: 64]), .acc(arr_out[1][7] ));
  PE pe_1_8  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq9 ), .left_in(left_seq8 [134:126]), .top_in(top_seq1 [ 63: 56]), .pe_rst_seq(             ), .right_out(left_seq9 [134:126]), .bottom_out(top_seq2 [ 63: 56]), .acc(arr_out[1][8] ));
  PE pe_1_9  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq10), .left_in(left_seq9 [134:126]), .top_in(top_seq1 [ 55: 48]), .pe_rst_seq(             ), .right_out(left_seq10[134:126]), .bottom_out(top_seq2 [ 55: 48]), .acc(arr_out[1][9] ));
  PE pe_1_10 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq11), .left_in(left_seq10[134:126]), .top_in(top_seq1 [ 47: 40]), .pe_rst_seq(             ), .right_out(left_seq11[134:126]), .bottom_out(top_seq2 [ 47: 40]), .acc(arr_out[1][10]));
  PE pe_1_11 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq12), .left_in(left_seq11[134:126]), .top_in(top_seq1 [ 39: 32]), .pe_rst_seq(             ), .right_out(left_seq12[134:126]), .bottom_out(top_seq2 [ 39: 32]), .acc(arr_out[1][11]));
  PE pe_1_12 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq13), .left_in(left_seq12[134:126]), .top_in(top_seq1 [ 31: 24]), .pe_rst_seq(             ), .right_out(left_seq13[134:126]), .bottom_out(top_seq2 [ 31: 24]), .acc(arr_out[1][12]));
  PE pe_1_13 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq14), .left_in(left_seq13[134:126]), .top_in(top_seq1 [ 23: 16]), .pe_rst_seq(             ), .right_out(left_seq14[134:126]), .bottom_out(top_seq2 [ 23: 16]), .acc(arr_out[1][13]));
  PE pe_1_14 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq14[134:126]), .top_in(top_seq1 [ 15:  8]), .pe_rst_seq(             ), .right_out(left_seq15[134:126]), .bottom_out(top_seq2 [ 15:  8]), .acc(arr_out[1][14]));
  PE pe_1_15 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq16), .left_in(left_seq15[134:126]), .top_in(top_seq1 [  7:  0]), .pe_rst_seq(sys_rst_seq17), .right_out(     right[134:126]), .bottom_out(top_seq2 [  7:  0]), .acc(arr_out[1][15]));
  
  PE pe_2_0  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq2),  .left_in(left_seq0 [125:117]), .top_in(top_seq2 [127:120]), .pe_rst_seq(             ), .right_out(left_seq1 [125:117]), .bottom_out(top_seq3 [127:120]), .acc(arr_out[2][0] ));
  PE pe_2_1  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq3),  .left_in(left_seq1 [125:117]), .top_in(top_seq2 [119:112]), .pe_rst_seq(             ), .right_out(left_seq2 [125:117]), .bottom_out(top_seq3 [119:112]), .acc(arr_out[2][1] ));
  PE pe_2_2  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq4),  .left_in(left_seq2 [125:117]), .top_in(top_seq2 [111:104]), .pe_rst_seq(             ), .right_out(left_seq3 [125:117]), .bottom_out(top_seq3 [111:104]), .acc(arr_out[2][2] ));
  PE pe_2_3  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq5),  .left_in(left_seq3 [125:117]), .top_in(top_seq2 [103: 96]), .pe_rst_seq(             ), .right_out(left_seq4 [125:117]), .bottom_out(top_seq3 [103: 96]), .acc(arr_out[2][3] ));
  PE pe_2_4  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq6),  .left_in(left_seq4 [125:117]), .top_in(top_seq2 [ 95: 88]), .pe_rst_seq(             ), .right_out(left_seq5 [125:117]), .bottom_out(top_seq3 [ 95: 88]), .acc(arr_out[2][4] ));
  PE pe_2_5  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq7),  .left_in(left_seq5 [125:117]), .top_in(top_seq2 [ 87: 80]), .pe_rst_seq(             ), .right_out(left_seq6 [125:117]), .bottom_out(top_seq3 [ 87: 80]), .acc(arr_out[2][5] ));
  PE pe_2_6  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq8),  .left_in(left_seq6 [125:117]), .top_in(top_seq2 [ 79: 72]), .pe_rst_seq(             ), .right_out(left_seq7 [125:117]), .bottom_out(top_seq3 [ 79: 72]), .acc(arr_out[2][6] ));
  PE pe_2_7  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq9),  .left_in(left_seq7 [125:117]), .top_in(top_seq2 [ 71: 64]), .pe_rst_seq(             ), .right_out(left_seq8 [125:117]), .bottom_out(top_seq3 [ 71: 64]), .acc(arr_out[2][7] ));
  PE pe_2_8  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq10), .left_in(left_seq8 [125:117]), .top_in(top_seq2 [ 63: 56]), .pe_rst_seq(             ), .right_out(left_seq9 [125:117]), .bottom_out(top_seq3 [ 63: 56]), .acc(arr_out[2][8] ));
  PE pe_2_9  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq11), .left_in(left_seq9 [125:117]), .top_in(top_seq2 [ 55: 48]), .pe_rst_seq(             ), .right_out(left_seq10[125:117]), .bottom_out(top_seq3 [ 55: 48]), .acc(arr_out[2][9] ));
  PE pe_2_10 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq12), .left_in(left_seq10[125:117]), .top_in(top_seq2 [ 47: 40]), .pe_rst_seq(             ), .right_out(left_seq11[125:117]), .bottom_out(top_seq3 [ 47: 40]), .acc(arr_out[2][10]));
  PE pe_2_11 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq13), .left_in(left_seq11[125:117]), .top_in(top_seq2 [ 39: 32]), .pe_rst_seq(             ), .right_out(left_seq12[125:117]), .bottom_out(top_seq3 [ 39: 32]), .acc(arr_out[2][11]));
  PE pe_2_12 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq14), .left_in(left_seq12[125:117]), .top_in(top_seq2 [ 31: 24]), .pe_rst_seq(             ), .right_out(left_seq13[125:117]), .bottom_out(top_seq3 [ 31: 24]), .acc(arr_out[2][12]));
  PE pe_2_13 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq13[125:117]), .top_in(top_seq2 [ 23: 16]), .pe_rst_seq(             ), .right_out(left_seq14[125:117]), .bottom_out(top_seq3 [ 23: 16]), .acc(arr_out[2][13]));
  PE pe_2_14 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq16), .left_in(left_seq14[125:117]), .top_in(top_seq2 [ 15:  8]), .pe_rst_seq(             ), .right_out(left_seq15[125:117]), .bottom_out(top_seq3 [ 15:  8]), .acc(arr_out[2][14]));
  PE pe_2_15 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq17), .left_in(left_seq15[125:117]), .top_in(top_seq2 [  7:  0]), .pe_rst_seq(sys_rst_seq18), .right_out(     right[125:117]), .bottom_out(top_seq3 [  7:  0]), .acc(arr_out[2][15]));
  
  PE pe_3_0  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq3),  .left_in(left_seq0 [116:108]), .top_in(top_seq3 [127:120]), .pe_rst_seq(             ), .right_out(left_seq1 [116:108]), .bottom_out(top_seq4 [127:120]), .acc(arr_out[3][0] ));
  PE pe_3_1  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq4),  .left_in(left_seq1 [116:108]), .top_in(top_seq3 [119:112]), .pe_rst_seq(             ), .right_out(left_seq2 [116:108]), .bottom_out(top_seq4 [119:112]), .acc(arr_out[3][1] ));
  PE pe_3_2  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq5),  .left_in(left_seq2 [116:108]), .top_in(top_seq3 [111:104]), .pe_rst_seq(             ), .right_out(left_seq3 [116:108]), .bottom_out(top_seq4 [111:104]), .acc(arr_out[3][2] ));
  PE pe_3_3  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq6),  .left_in(left_seq3 [116:108]), .top_in(top_seq3 [103: 96]), .pe_rst_seq(             ), .right_out(left_seq4 [116:108]), .bottom_out(top_seq4 [103: 96]), .acc(arr_out[3][3] ));
  PE pe_3_4  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq7),  .left_in(left_seq4 [116:108]), .top_in(top_seq3 [ 95: 88]), .pe_rst_seq(             ), .right_out(left_seq5 [116:108]), .bottom_out(top_seq4 [ 95: 88]), .acc(arr_out[3][4] ));
  PE pe_3_5  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq8),  .left_in(left_seq5 [116:108]), .top_in(top_seq3 [ 87: 80]), .pe_rst_seq(             ), .right_out(left_seq6 [116:108]), .bottom_out(top_seq4 [ 87: 80]), .acc(arr_out[3][5] ));
  PE pe_3_6  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq9),  .left_in(left_seq6 [116:108]), .top_in(top_seq3 [ 79: 72]), .pe_rst_seq(             ), .right_out(left_seq7 [116:108]), .bottom_out(top_seq4 [ 79: 72]), .acc(arr_out[3][6] ));
  PE pe_3_7  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq10), .left_in(left_seq7 [116:108]), .top_in(top_seq3 [ 71: 64]), .pe_rst_seq(             ), .right_out(left_seq8 [116:108]), .bottom_out(top_seq4 [ 71: 64]), .acc(arr_out[3][7] ));
  PE pe_3_8  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq11), .left_in(left_seq8 [116:108]), .top_in(top_seq3 [ 63: 56]), .pe_rst_seq(             ), .right_out(left_seq9 [116:108]), .bottom_out(top_seq4 [ 63: 56]), .acc(arr_out[3][8] ));
  PE pe_3_9  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq12), .left_in(left_seq9 [116:108]), .top_in(top_seq3 [ 55: 48]), .pe_rst_seq(             ), .right_out(left_seq10[116:108]), .bottom_out(top_seq4 [ 55: 48]), .acc(arr_out[3][9] ));
  PE pe_3_10 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq13), .left_in(left_seq10[116:108]), .top_in(top_seq3 [ 47: 40]), .pe_rst_seq(             ), .right_out(left_seq11[116:108]), .bottom_out(top_seq4 [ 47: 40]), .acc(arr_out[3][10]));
  PE pe_3_11 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq14), .left_in(left_seq11[116:108]), .top_in(top_seq3 [ 39: 32]), .pe_rst_seq(             ), .right_out(left_seq12[116:108]), .bottom_out(top_seq4 [ 39: 32]), .acc(arr_out[3][11]));
  PE pe_3_12 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq12[116:108]), .top_in(top_seq3 [ 31: 24]), .pe_rst_seq(             ), .right_out(left_seq13[116:108]), .bottom_out(top_seq4 [ 31: 24]), .acc(arr_out[3][12]));
  PE pe_3_13 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq16), .left_in(left_seq13[116:108]), .top_in(top_seq3 [ 23: 16]), .pe_rst_seq(             ), .right_out(left_seq14[116:108]), .bottom_out(top_seq4 [ 23: 16]), .acc(arr_out[3][13]));
  PE pe_3_14 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq17), .left_in(left_seq14[116:108]), .top_in(top_seq3 [ 15:  8]), .pe_rst_seq(             ), .right_out(left_seq15[116:108]), .bottom_out(top_seq4 [ 15:  8]), .acc(arr_out[3][14]));
  PE pe_3_15 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq18), .left_in(left_seq15[116:108]), .top_in(top_seq3 [  7:  0]), .pe_rst_seq(sys_rst_seq19), .right_out(     right[116:108]), .bottom_out(top_seq4 [  7:  0]), .acc(arr_out[3][15]));
  
  PE pe_4_0  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq4),  .left_in(left_seq0 [107: 99]), .top_in(top_seq4 [127:120]), .pe_rst_seq(             ), .right_out(left_seq1 [107: 99]), .bottom_out(top_seq5 [127:120]), .acc(arr_out[4][0] ));
  PE pe_4_1  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq5),  .left_in(left_seq1 [107: 99]), .top_in(top_seq4 [119:112]), .pe_rst_seq(             ), .right_out(left_seq2 [107: 99]), .bottom_out(top_seq5 [119:112]), .acc(arr_out[4][1] ));
  PE pe_4_2  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq6),  .left_in(left_seq2 [107: 99]), .top_in(top_seq4 [111:104]), .pe_rst_seq(             ), .right_out(left_seq3 [107: 99]), .bottom_out(top_seq5 [111:104]), .acc(arr_out[4][2] ));
  PE pe_4_3  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq7),  .left_in(left_seq3 [107: 99]), .top_in(top_seq4 [103: 96]), .pe_rst_seq(             ), .right_out(left_seq4 [107: 99]), .bottom_out(top_seq5 [103: 96]), .acc(arr_out[4][3] ));
  PE pe_4_4  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq8),  .left_in(left_seq4 [107: 99]), .top_in(top_seq4 [ 95: 88]), .pe_rst_seq(             ), .right_out(left_seq5 [107: 99]), .bottom_out(top_seq5 [ 95: 88]), .acc(arr_out[4][4] ));
  PE pe_4_5  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq9),  .left_in(left_seq5 [107: 99]), .top_in(top_seq4 [ 87: 80]), .pe_rst_seq(             ), .right_out(left_seq6 [107: 99]), .bottom_out(top_seq5 [ 87: 80]), .acc(arr_out[4][5] ));
  PE pe_4_6  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq10), .left_in(left_seq6 [107: 99]), .top_in(top_seq4 [ 79: 72]), .pe_rst_seq(             ), .right_out(left_seq7 [107: 99]), .bottom_out(top_seq5 [ 79: 72]), .acc(arr_out[4][6] ));
  PE pe_4_7  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq11), .left_in(left_seq7 [107: 99]), .top_in(top_seq4 [ 71: 64]), .pe_rst_seq(             ), .right_out(left_seq8 [107: 99]), .bottom_out(top_seq5 [ 71: 64]), .acc(arr_out[4][7] ));
  PE pe_4_8  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq12), .left_in(left_seq8 [107: 99]), .top_in(top_seq4 [ 63: 56]), .pe_rst_seq(             ), .right_out(left_seq9 [107: 99]), .bottom_out(top_seq5 [ 63: 56]), .acc(arr_out[4][8] ));
  PE pe_4_9  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq13), .left_in(left_seq9 [107: 99]), .top_in(top_seq4 [ 55: 48]), .pe_rst_seq(             ), .right_out(left_seq10[107: 99]), .bottom_out(top_seq5 [ 55: 48]), .acc(arr_out[4][9] ));
  PE pe_4_10 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq14), .left_in(left_seq10[107: 99]), .top_in(top_seq4 [ 47: 40]), .pe_rst_seq(             ), .right_out(left_seq11[107: 99]), .bottom_out(top_seq5 [ 47: 40]), .acc(arr_out[4][10]));
  PE pe_4_11 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq11[107: 99]), .top_in(top_seq4 [ 39: 32]), .pe_rst_seq(             ), .right_out(left_seq12[107: 99]), .bottom_out(top_seq5 [ 39: 32]), .acc(arr_out[4][11]));
  PE pe_4_12 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq16), .left_in(left_seq12[107: 99]), .top_in(top_seq4 [ 31: 24]), .pe_rst_seq(             ), .right_out(left_seq13[107: 99]), .bottom_out(top_seq5 [ 31: 24]), .acc(arr_out[4][12]));
  PE pe_4_13 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq17), .left_in(left_seq13[107: 99]), .top_in(top_seq4 [ 23: 16]), .pe_rst_seq(             ), .right_out(left_seq14[107: 99]), .bottom_out(top_seq5 [ 23: 16]), .acc(arr_out[4][13]));
  PE pe_4_14 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq18), .left_in(left_seq14[107: 99]), .top_in(top_seq4 [ 15:  8]), .pe_rst_seq(             ), .right_out(left_seq15[107: 99]), .bottom_out(top_seq5 [ 15:  8]), .acc(arr_out[4][14]));
  PE pe_4_15 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq19), .left_in(left_seq15[107: 99]), .top_in(top_seq4 [  7:  0]), .pe_rst_seq(sys_rst_seq20), .right_out(     right[107: 99]), .bottom_out(top_seq5 [  7:  0]), .acc(arr_out[4][15]));
  
  PE pe_5_0  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq5),  .left_in(left_seq0 [ 98: 90]), .top_in(top_seq5 [127:120]), .pe_rst_seq(             ), .right_out(left_seq1 [ 98: 90]), .bottom_out(top_seq6 [127:120]), .acc(arr_out[5][0] ));
  PE pe_5_1  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq6),  .left_in(left_seq1 [ 98: 90]), .top_in(top_seq5 [119:112]), .pe_rst_seq(             ), .right_out(left_seq2 [ 98: 90]), .bottom_out(top_seq6 [119:112]), .acc(arr_out[5][1] ));
  PE pe_5_2  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq7),  .left_in(left_seq2 [ 98: 90]), .top_in(top_seq5 [111:104]), .pe_rst_seq(             ), .right_out(left_seq3 [ 98: 90]), .bottom_out(top_seq6 [111:104]), .acc(arr_out[5][2] ));
  PE pe_5_3  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq8),  .left_in(left_seq3 [ 98: 90]), .top_in(top_seq5 [103: 96]), .pe_rst_seq(             ), .right_out(left_seq4 [ 98: 90]), .bottom_out(top_seq6 [103: 96]), .acc(arr_out[5][3] ));
  PE pe_5_4  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq9),  .left_in(left_seq4 [ 98: 90]), .top_in(top_seq5 [ 95: 88]), .pe_rst_seq(             ), .right_out(left_seq5 [ 98: 90]), .bottom_out(top_seq6 [ 95: 88]), .acc(arr_out[5][4] ));
  PE pe_5_5  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq10), .left_in(left_seq5 [ 98: 90]), .top_in(top_seq5 [ 87: 80]), .pe_rst_seq(             ), .right_out(left_seq6 [ 98: 90]), .bottom_out(top_seq6 [ 87: 80]), .acc(arr_out[5][5] ));
  PE pe_5_6  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq11), .left_in(left_seq6 [ 98: 90]), .top_in(top_seq5 [ 79: 72]), .pe_rst_seq(             ), .right_out(left_seq7 [ 98: 90]), .bottom_out(top_seq6 [ 79: 72]), .acc(arr_out[5][6] ));
  PE pe_5_7  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq12), .left_in(left_seq7 [ 98: 90]), .top_in(top_seq5 [ 71: 64]), .pe_rst_seq(             ), .right_out(left_seq8 [ 98: 90]), .bottom_out(top_seq6 [ 71: 64]), .acc(arr_out[5][7] ));
  PE pe_5_8  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq13), .left_in(left_seq8 [ 98: 90]), .top_in(top_seq5 [ 63: 56]), .pe_rst_seq(             ), .right_out(left_seq9 [ 98: 90]), .bottom_out(top_seq6 [ 63: 56]), .acc(arr_out[5][8] ));
  PE pe_5_9  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq14), .left_in(left_seq9 [ 98: 90]), .top_in(top_seq5 [ 55: 48]), .pe_rst_seq(             ), .right_out(left_seq10[ 98: 90]), .bottom_out(top_seq6 [ 55: 48]), .acc(arr_out[5][9] ));
  PE pe_5_10 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq10[ 98: 90]), .top_in(top_seq5 [ 47: 40]), .pe_rst_seq(             ), .right_out(left_seq11[ 98: 90]), .bottom_out(top_seq6 [ 47: 40]), .acc(arr_out[5][10]));
  PE pe_5_11 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq16), .left_in(left_seq11[ 98: 90]), .top_in(top_seq5 [ 39: 32]), .pe_rst_seq(             ), .right_out(left_seq12[ 98: 90]), .bottom_out(top_seq6 [ 39: 32]), .acc(arr_out[5][11]));
  PE pe_5_12 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq17), .left_in(left_seq12[ 98: 90]), .top_in(top_seq5 [ 31: 24]), .pe_rst_seq(             ), .right_out(left_seq13[ 98: 90]), .bottom_out(top_seq6 [ 31: 24]), .acc(arr_out[5][12]));
  PE pe_5_13 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq18), .left_in(left_seq13[ 98: 90]), .top_in(top_seq5 [ 23: 16]), .pe_rst_seq(             ), .right_out(left_seq14[ 98: 90]), .bottom_out(top_seq6 [ 23: 16]), .acc(arr_out[5][13]));
  PE pe_5_14 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq19), .left_in(left_seq14[ 98: 90]), .top_in(top_seq5 [ 15:  8]), .pe_rst_seq(             ), .right_out(left_seq15[ 98: 90]), .bottom_out(top_seq6 [ 15:  8]), .acc(arr_out[5][14]));
  PE pe_5_15 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq20), .left_in(left_seq15[ 98: 90]), .top_in(top_seq5 [  7:  0]), .pe_rst_seq(sys_rst_seq21), .right_out(     right[ 98: 90]), .bottom_out(top_seq6 [  7:  0]), .acc(arr_out[5][15]));
  
  PE pe_6_0  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq6),  .left_in(left_seq0 [ 89: 81]), .top_in(top_seq6 [127:120]), .pe_rst_seq(             ), .right_out(left_seq1 [ 89: 81]), .bottom_out(top_seq7 [127:120]), .acc(arr_out[6][0] ));
  PE pe_6_1  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq7),  .left_in(left_seq1 [ 89: 81]), .top_in(top_seq6 [119:112]), .pe_rst_seq(             ), .right_out(left_seq2 [ 89: 81]), .bottom_out(top_seq7 [119:112]), .acc(arr_out[6][1] ));
  PE pe_6_2  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq8),  .left_in(left_seq2 [ 89: 81]), .top_in(top_seq6 [111:104]), .pe_rst_seq(             ), .right_out(left_seq3 [ 89: 81]), .bottom_out(top_seq7 [111:104]), .acc(arr_out[6][2] ));
  PE pe_6_3  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq9),  .left_in(left_seq3 [ 89: 81]), .top_in(top_seq6 [103: 96]), .pe_rst_seq(             ), .right_out(left_seq4 [ 89: 81]), .bottom_out(top_seq7 [103: 96]), .acc(arr_out[6][3] ));
  PE pe_6_4  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq10), .left_in(left_seq4 [ 89: 81]), .top_in(top_seq6 [ 95: 88]), .pe_rst_seq(             ), .right_out(left_seq5 [ 89: 81]), .bottom_out(top_seq7 [ 95: 88]), .acc(arr_out[6][4] ));
  PE pe_6_5  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq11), .left_in(left_seq5 [ 89: 81]), .top_in(top_seq6 [ 87: 80]), .pe_rst_seq(             ), .right_out(left_seq6 [ 89: 81]), .bottom_out(top_seq7 [ 87: 80]), .acc(arr_out[6][5] ));
  PE pe_6_6  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq12), .left_in(left_seq6 [ 89: 81]), .top_in(top_seq6 [ 79: 72]), .pe_rst_seq(             ), .right_out(left_seq7 [ 89: 81]), .bottom_out(top_seq7 [ 79: 72]), .acc(arr_out[6][6] ));
  PE pe_6_7  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq13), .left_in(left_seq7 [ 89: 81]), .top_in(top_seq6 [ 71: 64]), .pe_rst_seq(             ), .right_out(left_seq8 [ 89: 81]), .bottom_out(top_seq7 [ 71: 64]), .acc(arr_out[6][7] ));
  PE pe_6_8  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq14), .left_in(left_seq8 [ 89: 81]), .top_in(top_seq6 [ 63: 56]), .pe_rst_seq(             ), .right_out(left_seq9 [ 89: 81]), .bottom_out(top_seq7 [ 63: 56]), .acc(arr_out[6][8] ));
  PE pe_6_9  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq9 [ 89: 81]), .top_in(top_seq6 [ 55: 48]), .pe_rst_seq(             ), .right_out(left_seq10[ 89: 81]), .bottom_out(top_seq7 [ 55: 48]), .acc(arr_out[6][9] ));
  PE pe_6_10 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq16), .left_in(left_seq10[ 89: 81]), .top_in(top_seq6 [ 47: 40]), .pe_rst_seq(             ), .right_out(left_seq11[ 89: 81]), .bottom_out(top_seq7 [ 47: 40]), .acc(arr_out[6][10]));
  PE pe_6_11 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq17), .left_in(left_seq11[ 89: 81]), .top_in(top_seq6 [ 39: 32]), .pe_rst_seq(             ), .right_out(left_seq12[ 89: 81]), .bottom_out(top_seq7 [ 39: 32]), .acc(arr_out[6][11]));
  PE pe_6_12 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq18), .left_in(left_seq12[ 89: 81]), .top_in(top_seq6 [ 31: 24]), .pe_rst_seq(             ), .right_out(left_seq13[ 89: 81]), .bottom_out(top_seq7 [ 31: 24]), .acc(arr_out[6][12]));
  PE pe_6_13 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq19), .left_in(left_seq13[ 89: 81]), .top_in(top_seq6 [ 23: 16]), .pe_rst_seq(             ), .right_out(left_seq14[ 89: 81]), .bottom_out(top_seq7 [ 23: 16]), .acc(arr_out[6][13]));
  PE pe_6_14 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq20), .left_in(left_seq14[ 89: 81]), .top_in(top_seq6 [ 15:  8]), .pe_rst_seq(             ), .right_out(left_seq15[ 89: 81]), .bottom_out(top_seq7 [ 15:  8]), .acc(arr_out[6][14]));
  PE pe_6_15 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq21), .left_in(left_seq15[ 89: 81]), .top_in(top_seq6 [  7:  0]), .pe_rst_seq(sys_rst_seq22), .right_out(     right[ 89: 81]), .bottom_out(top_seq7 [  7:  0]), .acc(arr_out[6][15]));
  
  PE pe_7_0  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq7),  .left_in(left_seq0 [ 80: 72]), .top_in(top_seq7 [127:120]), .pe_rst_seq(             ), .right_out(left_seq1 [ 80: 72]), .bottom_out(top_seq8 [127:120]), .acc(arr_out[7][0] ));
  PE pe_7_1  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq8),  .left_in(left_seq1 [ 80: 72]), .top_in(top_seq7 [119:112]), .pe_rst_seq(             ), .right_out(left_seq2 [ 80: 72]), .bottom_out(top_seq8 [119:112]), .acc(arr_out[7][1] ));
  PE pe_7_2  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq9),  .left_in(left_seq2 [ 80: 72]), .top_in(top_seq7 [111:104]), .pe_rst_seq(             ), .right_out(left_seq3 [ 80: 72]), .bottom_out(top_seq8 [111:104]), .acc(arr_out[7][2] ));
  PE pe_7_3  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq10), .left_in(left_seq3 [ 80: 72]), .top_in(top_seq7 [103: 96]), .pe_rst_seq(             ), .right_out(left_seq4 [ 80: 72]), .bottom_out(top_seq8 [103: 96]), .acc(arr_out[7][3] ));
  PE pe_7_4  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq11), .left_in(left_seq4 [ 80: 72]), .top_in(top_seq7 [ 95: 88]), .pe_rst_seq(             ), .right_out(left_seq5 [ 80: 72]), .bottom_out(top_seq8 [ 95: 88]), .acc(arr_out[7][4] ));
  PE pe_7_5  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq12), .left_in(left_seq5 [ 80: 72]), .top_in(top_seq7 [ 87: 80]), .pe_rst_seq(             ), .right_out(left_seq6 [ 80: 72]), .bottom_out(top_seq8 [ 87: 80]), .acc(arr_out[7][5] ));
  PE pe_7_6  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq13), .left_in(left_seq6 [ 80: 72]), .top_in(top_seq7 [ 79: 72]), .pe_rst_seq(             ), .right_out(left_seq7 [ 80: 72]), .bottom_out(top_seq8 [ 79: 72]), .acc(arr_out[7][6] ));
  PE pe_7_7  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq14), .left_in(left_seq7 [ 80: 72]), .top_in(top_seq7 [ 71: 64]), .pe_rst_seq(             ), .right_out(left_seq8 [ 80: 72]), .bottom_out(top_seq8 [ 71: 64]), .acc(arr_out[7][7] ));
  PE pe_7_8  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq8 [ 80: 72]), .top_in(top_seq7 [ 63: 56]), .pe_rst_seq(             ), .right_out(left_seq9 [ 80: 72]), .bottom_out(top_seq8 [ 63: 56]), .acc(arr_out[7][8] ));
  PE pe_7_9  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq16), .left_in(left_seq9 [ 80: 72]), .top_in(top_seq7 [ 55: 48]), .pe_rst_seq(             ), .right_out(left_seq10[ 80: 72]), .bottom_out(top_seq8 [ 55: 48]), .acc(arr_out[7][9] ));
  PE pe_7_10 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq17), .left_in(left_seq10[ 80: 72]), .top_in(top_seq7 [ 47: 40]), .pe_rst_seq(             ), .right_out(left_seq11[ 80: 72]), .bottom_out(top_seq8 [ 47: 40]), .acc(arr_out[7][10]));
  PE pe_7_11 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq18), .left_in(left_seq11[ 80: 72]), .top_in(top_seq7 [ 39: 32]), .pe_rst_seq(             ), .right_out(left_seq12[ 80: 72]), .bottom_out(top_seq8 [ 39: 32]), .acc(arr_out[7][11]));
  PE pe_7_12 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq19), .left_in(left_seq12[ 80: 72]), .top_in(top_seq7 [ 31: 24]), .pe_rst_seq(             ), .right_out(left_seq13[ 80: 72]), .bottom_out(top_seq8 [ 31: 24]), .acc(arr_out[7][12]));
  PE pe_7_13 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq20), .left_in(left_seq13[ 80: 72]), .top_in(top_seq7 [ 23: 16]), .pe_rst_seq(             ), .right_out(left_seq14[ 80: 72]), .bottom_out(top_seq8 [ 23: 16]), .acc(arr_out[7][13]));
  PE pe_7_14 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq21), .left_in(left_seq14[ 80: 72]), .top_in(top_seq7 [ 15:  8]), .pe_rst_seq(             ), .right_out(left_seq15[ 80: 72]), .bottom_out(top_seq8 [ 15:  8]), .acc(arr_out[7][14]));
  PE pe_7_15 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq22), .left_in(left_seq15[ 80: 72]), .top_in(top_seq7 [  7:  0]), .pe_rst_seq(sys_rst_seq23), .right_out(     right[ 80: 72]), .bottom_out(top_seq8 [  7:  0]), .acc(arr_out[7][15]));
  
  PE pe_8_0  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq8),  .left_in(left_seq0 [ 71: 63]), .top_in(top_seq8 [127:120]), .pe_rst_seq(             ), .right_out(left_seq1 [ 71: 63]), .bottom_out(top_seq9 [127:120]), .acc(arr_out[8][0] ));
  PE pe_8_1  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq9),  .left_in(left_seq1 [ 71: 63]), .top_in(top_seq8 [119:112]), .pe_rst_seq(             ), .right_out(left_seq2 [ 71: 63]), .bottom_out(top_seq9 [119:112]), .acc(arr_out[8][1] ));
  PE pe_8_2  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq10), .left_in(left_seq2 [ 71: 63]), .top_in(top_seq8 [111:104]), .pe_rst_seq(             ), .right_out(left_seq3 [ 71: 63]), .bottom_out(top_seq9 [111:104]), .acc(arr_out[8][2] ));
  PE pe_8_3  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq11), .left_in(left_seq3 [ 71: 63]), .top_in(top_seq8 [103: 96]), .pe_rst_seq(             ), .right_out(left_seq4 [ 71: 63]), .bottom_out(top_seq9 [103: 96]), .acc(arr_out[8][3] ));
  PE pe_8_4  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq12), .left_in(left_seq4 [ 71: 63]), .top_in(top_seq8 [ 95: 88]), .pe_rst_seq(             ), .right_out(left_seq5 [ 71: 63]), .bottom_out(top_seq9 [ 95: 88]), .acc(arr_out[8][4] ));
  PE pe_8_5  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq13), .left_in(left_seq5 [ 71: 63]), .top_in(top_seq8 [ 87: 80]), .pe_rst_seq(             ), .right_out(left_seq6 [ 71: 63]), .bottom_out(top_seq9 [ 87: 80]), .acc(arr_out[8][5] ));
  PE pe_8_6  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq14), .left_in(left_seq6 [ 71: 63]), .top_in(top_seq8 [ 79: 72]), .pe_rst_seq(             ), .right_out(left_seq7 [ 71: 63]), .bottom_out(top_seq9 [ 79: 72]), .acc(arr_out[8][6] ));
  PE pe_8_7  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq7 [ 71: 63]), .top_in(top_seq8 [ 71: 64]), .pe_rst_seq(             ), .right_out(left_seq8 [ 71: 63]), .bottom_out(top_seq9 [ 71: 64]), .acc(arr_out[8][7] ));
  PE pe_8_8  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq16), .left_in(left_seq8 [ 71: 63]), .top_in(top_seq8 [ 63: 56]), .pe_rst_seq(             ), .right_out(left_seq9 [ 71: 63]), .bottom_out(top_seq9 [ 63: 56]), .acc(arr_out[8][8] ));
  PE pe_8_9  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq17), .left_in(left_seq9 [ 71: 63]), .top_in(top_seq8 [ 55: 48]), .pe_rst_seq(             ), .right_out(left_seq10[ 71: 63]), .bottom_out(top_seq9 [ 55: 48]), .acc(arr_out[8][9] ));
  PE pe_8_10 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq18), .left_in(left_seq10[ 71: 63]), .top_in(top_seq8 [ 47: 40]), .pe_rst_seq(             ), .right_out(left_seq11[ 71: 63]), .bottom_out(top_seq9 [ 47: 40]), .acc(arr_out[8][10]));
  PE pe_8_11 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq19), .left_in(left_seq11[ 71: 63]), .top_in(top_seq8 [ 39: 32]), .pe_rst_seq(             ), .right_out(left_seq12[ 71: 63]), .bottom_out(top_seq9 [ 39: 32]), .acc(arr_out[8][11]));
  PE pe_8_12 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq20), .left_in(left_seq12[ 71: 63]), .top_in(top_seq8 [ 31: 24]), .pe_rst_seq(             ), .right_out(left_seq13[ 71: 63]), .bottom_out(top_seq9 [ 31: 24]), .acc(arr_out[8][12]));
  PE pe_8_13 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq21), .left_in(left_seq13[ 71: 63]), .top_in(top_seq8 [ 23: 16]), .pe_rst_seq(             ), .right_out(left_seq14[ 71: 63]), .bottom_out(top_seq9 [ 23: 16]), .acc(arr_out[8][13]));
  PE pe_8_14 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq22), .left_in(left_seq14[ 71: 63]), .top_in(top_seq8 [ 15:  8]), .pe_rst_seq(             ), .right_out(left_seq15[ 71: 63]), .bottom_out(top_seq9 [ 15:  8]), .acc(arr_out[8][14]));
  PE pe_8_15 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq23), .left_in(left_seq15[ 71: 63]), .top_in(top_seq8 [  7:  0]), .pe_rst_seq(sys_rst_seq24), .right_out(     right[ 71: 63]), .bottom_out(top_seq9 [  7:  0]), .acc(arr_out[8][15]));
  
  PE pe_9_0  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq9),  .left_in(left_seq0 [ 62: 54]), .top_in(top_seq9 [127:120]), .pe_rst_seq(             ), .right_out(left_seq1 [ 62: 54]), .bottom_out(top_seq10[127:120]), .acc(arr_out[9][0] ));
  PE pe_9_1  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq10), .left_in(left_seq1 [ 62: 54]), .top_in(top_seq9 [119:112]), .pe_rst_seq(             ), .right_out(left_seq2 [ 62: 54]), .bottom_out(top_seq10[119:112]), .acc(arr_out[9][1] ));
  PE pe_9_2  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq11), .left_in(left_seq2 [ 62: 54]), .top_in(top_seq9 [111:104]), .pe_rst_seq(             ), .right_out(left_seq3 [ 62: 54]), .bottom_out(top_seq10[111:104]), .acc(arr_out[9][2] ));
  PE pe_9_3  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq12), .left_in(left_seq3 [ 62: 54]), .top_in(top_seq9 [103: 96]), .pe_rst_seq(             ), .right_out(left_seq4 [ 62: 54]), .bottom_out(top_seq10[103: 96]), .acc(arr_out[9][3] ));
  PE pe_9_4  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq13), .left_in(left_seq4 [ 62: 54]), .top_in(top_seq9 [ 95: 88]), .pe_rst_seq(             ), .right_out(left_seq5 [ 62: 54]), .bottom_out(top_seq10[ 95: 88]), .acc(arr_out[9][4] ));
  PE pe_9_5  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq14), .left_in(left_seq5 [ 62: 54]), .top_in(top_seq9 [ 87: 80]), .pe_rst_seq(             ), .right_out(left_seq6 [ 62: 54]), .bottom_out(top_seq10[ 87: 80]), .acc(arr_out[9][5] ));
  PE pe_9_6  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq6 [ 62: 54]), .top_in(top_seq9 [ 79: 72]), .pe_rst_seq(             ), .right_out(left_seq7 [ 62: 54]), .bottom_out(top_seq10[ 79: 72]), .acc(arr_out[9][6] ));
  PE pe_9_7  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq16), .left_in(left_seq7 [ 62: 54]), .top_in(top_seq9 [ 71: 64]), .pe_rst_seq(             ), .right_out(left_seq8 [ 62: 54]), .bottom_out(top_seq10[ 71: 64]), .acc(arr_out[9][7] ));
  PE pe_9_8  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq17), .left_in(left_seq8 [ 62: 54]), .top_in(top_seq9 [ 63: 56]), .pe_rst_seq(             ), .right_out(left_seq9 [ 62: 54]), .bottom_out(top_seq10[ 63: 56]), .acc(arr_out[9][8] ));
  PE pe_9_9  (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq18), .left_in(left_seq9 [ 62: 54]), .top_in(top_seq9 [ 55: 48]), .pe_rst_seq(             ), .right_out(left_seq10[ 62: 54]), .bottom_out(top_seq10[ 55: 48]), .acc(arr_out[9][9] ));
  PE pe_9_10 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq19), .left_in(left_seq10[ 62: 54]), .top_in(top_seq9 [ 47: 40]), .pe_rst_seq(             ), .right_out(left_seq11[ 62: 54]), .bottom_out(top_seq10[ 47: 40]), .acc(arr_out[9][10]));
  PE pe_9_11 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq20), .left_in(left_seq11[ 62: 54]), .top_in(top_seq9 [ 39: 32]), .pe_rst_seq(             ), .right_out(left_seq12[ 62: 54]), .bottom_out(top_seq10[ 39: 32]), .acc(arr_out[9][11]));
  PE pe_9_12 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq21), .left_in(left_seq12[ 62: 54]), .top_in(top_seq9 [ 31: 24]), .pe_rst_seq(             ), .right_out(left_seq13[ 62: 54]), .bottom_out(top_seq10[ 31: 24]), .acc(arr_out[9][12]));
  PE pe_9_13 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq22), .left_in(left_seq13[ 62: 54]), .top_in(top_seq9 [ 23: 16]), .pe_rst_seq(             ), .right_out(left_seq14[ 62: 54]), .bottom_out(top_seq10[ 23: 16]), .acc(arr_out[9][13]));
  PE pe_9_14 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq23), .left_in(left_seq14[ 62: 54]), .top_in(top_seq9 [ 15:  8]), .pe_rst_seq(             ), .right_out(left_seq15[ 62: 54]), .bottom_out(top_seq10[ 15:  8]), .acc(arr_out[9][14]));
  PE pe_9_15 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq24), .left_in(left_seq15[ 62: 54]), .top_in(top_seq9 [  7:  0]), .pe_rst_seq(sys_rst_seq25), .right_out(     right[ 62: 54]), .bottom_out(top_seq10[  7:  0]), .acc(arr_out[9][15]));
  
  PE pe_10_0 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq10), .left_in(left_seq0 [ 53: 45]), .top_in(top_seq10[127:120]), .pe_rst_seq(             ), .right_out(left_seq1 [ 53: 45]), .bottom_out(top_seq11[127:120]), .acc(arr_out[10][0] ));
  PE pe_10_1 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq11), .left_in(left_seq1 [ 53: 45]), .top_in(top_seq10[119:112]), .pe_rst_seq(             ), .right_out(left_seq2 [ 53: 45]), .bottom_out(top_seq11[119:112]), .acc(arr_out[10][1] ));
  PE pe_10_2 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq12), .left_in(left_seq2 [ 53: 45]), .top_in(top_seq10[111:104]), .pe_rst_seq(             ), .right_out(left_seq3 [ 53: 45]), .bottom_out(top_seq11[111:104]), .acc(arr_out[10][2] ));
  PE pe_10_3 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq13), .left_in(left_seq3 [ 53: 45]), .top_in(top_seq10[103: 96]), .pe_rst_seq(             ), .right_out(left_seq4 [ 53: 45]), .bottom_out(top_seq11[103: 96]), .acc(arr_out[10][3] ));
  PE pe_10_4 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq14), .left_in(left_seq4 [ 53: 45]), .top_in(top_seq10[ 95: 88]), .pe_rst_seq(             ), .right_out(left_seq5 [ 53: 45]), .bottom_out(top_seq11[ 95: 88]), .acc(arr_out[10][4] ));
  PE pe_10_5 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq5 [ 53: 45]), .top_in(top_seq10[ 87: 80]), .pe_rst_seq(             ), .right_out(left_seq6 [ 53: 45]), .bottom_out(top_seq11[ 87: 80]), .acc(arr_out[10][5] ));
  PE pe_10_6 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq16), .left_in(left_seq6 [ 53: 45]), .top_in(top_seq10[ 79: 72]), .pe_rst_seq(             ), .right_out(left_seq7 [ 53: 45]), .bottom_out(top_seq11[ 79: 72]), .acc(arr_out[10][6] ));
  PE pe_10_7 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq17), .left_in(left_seq7 [ 53: 45]), .top_in(top_seq10[ 71: 64]), .pe_rst_seq(             ), .right_out(left_seq8 [ 53: 45]), .bottom_out(top_seq11[ 71: 64]), .acc(arr_out[10][7] ));
  PE pe_10_8 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq18), .left_in(left_seq8 [ 53: 45]), .top_in(top_seq10[ 63: 56]), .pe_rst_seq(             ), .right_out(left_seq9 [ 53: 45]), .bottom_out(top_seq11[ 63: 56]), .acc(arr_out[10][8] ));
  PE pe_10_9 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq19), .left_in(left_seq9 [ 53: 45]), .top_in(top_seq10[ 55: 48]), .pe_rst_seq(             ), .right_out(left_seq10[ 53: 45]), .bottom_out(top_seq11[ 55: 48]), .acc(arr_out[10][9] ));
  PE pe_10_10(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq20), .left_in(left_seq10[ 53: 45]), .top_in(top_seq10[ 47: 40]), .pe_rst_seq(             ), .right_out(left_seq11[ 53: 45]), .bottom_out(top_seq11[ 47: 40]), .acc(arr_out[10][10]));
  PE pe_10_11(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq21), .left_in(left_seq11[ 53: 45]), .top_in(top_seq10[ 39: 32]), .pe_rst_seq(             ), .right_out(left_seq12[ 53: 45]), .bottom_out(top_seq11[ 39: 32]), .acc(arr_out[10][11]));
  PE pe_10_12(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq22), .left_in(left_seq12[ 53: 45]), .top_in(top_seq10[ 31: 24]), .pe_rst_seq(             ), .right_out(left_seq13[ 53: 45]), .bottom_out(top_seq11[ 31: 24]), .acc(arr_out[10][12]));
  PE pe_10_13(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq23), .left_in(left_seq13[ 53: 45]), .top_in(top_seq10[ 23: 16]), .pe_rst_seq(             ), .right_out(left_seq14[ 53: 45]), .bottom_out(top_seq11[ 23: 16]), .acc(arr_out[10][13]));
  PE pe_10_14(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq24), .left_in(left_seq14[ 53: 45]), .top_in(top_seq10[ 15:  8]), .pe_rst_seq(             ), .right_out(left_seq15[ 53: 45]), .bottom_out(top_seq11[ 15:  8]), .acc(arr_out[10][14]));
  PE pe_10_15(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq25), .left_in(left_seq15[ 53: 45]), .top_in(top_seq10[  7:  0]), .pe_rst_seq(sys_rst_seq26), .right_out(     right[ 53: 45]), .bottom_out(top_seq11[  7:  0]), .acc(arr_out[10][15]));
  
  PE pe_11_0 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq11), .left_in(left_seq0 [ 44: 36]), .top_in(top_seq11[127:120]), .pe_rst_seq(             ), .right_out(left_seq1 [ 44: 36]), .bottom_out(top_seq12[127:120]), .acc(arr_out[11][0] ));
  PE pe_11_1 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq12), .left_in(left_seq1 [ 44: 36]), .top_in(top_seq11[119:112]), .pe_rst_seq(             ), .right_out(left_seq2 [ 44: 36]), .bottom_out(top_seq12[119:112]), .acc(arr_out[11][1] ));
  PE pe_11_2 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq13), .left_in(left_seq2 [ 44: 36]), .top_in(top_seq11[111:104]), .pe_rst_seq(             ), .right_out(left_seq3 [ 44: 36]), .bottom_out(top_seq12[111:104]), .acc(arr_out[11][2] ));
  PE pe_11_3 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq14), .left_in(left_seq3 [ 44: 36]), .top_in(top_seq11[103: 96]), .pe_rst_seq(             ), .right_out(left_seq4 [ 44: 36]), .bottom_out(top_seq12[103: 96]), .acc(arr_out[11][3] ));
  PE pe_11_4 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq4 [ 44: 36]), .top_in(top_seq11[ 95: 88]), .pe_rst_seq(             ), .right_out(left_seq5 [ 44: 36]), .bottom_out(top_seq12[ 95: 88]), .acc(arr_out[11][4] ));
  PE pe_11_5 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq16), .left_in(left_seq5 [ 44: 36]), .top_in(top_seq11[ 87: 80]), .pe_rst_seq(             ), .right_out(left_seq6 [ 44: 36]), .bottom_out(top_seq12[ 87: 80]), .acc(arr_out[11][5] ));
  PE pe_11_6 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq17), .left_in(left_seq6 [ 44: 36]), .top_in(top_seq11[ 79: 72]), .pe_rst_seq(             ), .right_out(left_seq7 [ 44: 36]), .bottom_out(top_seq12[ 79: 72]), .acc(arr_out[11][6] ));
  PE pe_11_7 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq18), .left_in(left_seq7 [ 44: 36]), .top_in(top_seq11[ 71: 64]), .pe_rst_seq(             ), .right_out(left_seq8 [ 44: 36]), .bottom_out(top_seq12[ 71: 64]), .acc(arr_out[11][7] ));
  PE pe_11_8 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq19), .left_in(left_seq8 [ 44: 36]), .top_in(top_seq11[ 63: 56]), .pe_rst_seq(             ), .right_out(left_seq9 [ 44: 36]), .bottom_out(top_seq12[ 63: 56]), .acc(arr_out[11][8] ));
  PE pe_11_9 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq20), .left_in(left_seq9 [ 44: 36]), .top_in(top_seq11[ 55: 48]), .pe_rst_seq(             ), .right_out(left_seq10[ 44: 36]), .bottom_out(top_seq12[ 55: 48]), .acc(arr_out[11][9] ));
  PE pe_11_10(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq21), .left_in(left_seq10[ 44: 36]), .top_in(top_seq11[ 47: 40]), .pe_rst_seq(             ), .right_out(left_seq11[ 44: 36]), .bottom_out(top_seq12[ 47: 40]), .acc(arr_out[11][10]));
  PE pe_11_11(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq22), .left_in(left_seq11[ 44: 36]), .top_in(top_seq11[ 39: 32]), .pe_rst_seq(             ), .right_out(left_seq12[ 44: 36]), .bottom_out(top_seq12[ 39: 32]), .acc(arr_out[11][11]));
  PE pe_11_12(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq23), .left_in(left_seq12[ 44: 36]), .top_in(top_seq11[ 31: 24]), .pe_rst_seq(             ), .right_out(left_seq13[ 44: 36]), .bottom_out(top_seq12[ 31: 24]), .acc(arr_out[11][12]));
  PE pe_11_13(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq24), .left_in(left_seq13[ 44: 36]), .top_in(top_seq11[ 23: 16]), .pe_rst_seq(             ), .right_out(left_seq14[ 44: 36]), .bottom_out(top_seq12[ 23: 16]), .acc(arr_out[11][13]));
  PE pe_11_14(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq25), .left_in(left_seq14[ 44: 36]), .top_in(top_seq11[ 15:  8]), .pe_rst_seq(             ), .right_out(left_seq15[ 44: 36]), .bottom_out(top_seq12[ 15:  8]), .acc(arr_out[11][14]));
  PE pe_11_15(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq26), .left_in(left_seq15[ 44: 36]), .top_in(top_seq11[  7:  0]), .pe_rst_seq(sys_rst_seq27), .right_out(     right[ 44: 36]), .bottom_out(top_seq12[  7:  0]), .acc(arr_out[11][15]));
  
  PE pe_12_0 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq12), .left_in(left_seq0 [ 35: 27]), .top_in(top_seq12[127:120]), .pe_rst_seq(             ), .right_out(left_seq1 [ 35: 27]), .bottom_out(top_seq13[127:120]), .acc(arr_out[12][0] ));
  PE pe_12_1 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq13), .left_in(left_seq1 [ 35: 27]), .top_in(top_seq12[119:112]), .pe_rst_seq(             ), .right_out(left_seq2 [ 35: 27]), .bottom_out(top_seq13[119:112]), .acc(arr_out[12][1] ));
  PE pe_12_2 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq14), .left_in(left_seq2 [ 35: 27]), .top_in(top_seq12[111:104]), .pe_rst_seq(             ), .right_out(left_seq3 [ 35: 27]), .bottom_out(top_seq13[111:104]), .acc(arr_out[12][2] ));
  PE pe_12_3 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq3 [ 35: 27]), .top_in(top_seq12[103: 96]), .pe_rst_seq(             ), .right_out(left_seq4 [ 35: 27]), .bottom_out(top_seq13[103: 96]), .acc(arr_out[12][3] ));
  PE pe_12_4 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq16), .left_in(left_seq4 [ 35: 27]), .top_in(top_seq12[ 95: 88]), .pe_rst_seq(             ), .right_out(left_seq5 [ 35: 27]), .bottom_out(top_seq13[ 95: 88]), .acc(arr_out[12][4] ));
  PE pe_12_5 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq17), .left_in(left_seq5 [ 35: 27]), .top_in(top_seq12[ 87: 80]), .pe_rst_seq(             ), .right_out(left_seq6 [ 35: 27]), .bottom_out(top_seq13[ 87: 80]), .acc(arr_out[12][5] ));
  PE pe_12_6 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq18), .left_in(left_seq6 [ 35: 27]), .top_in(top_seq12[ 79: 72]), .pe_rst_seq(             ), .right_out(left_seq7 [ 35: 27]), .bottom_out(top_seq13[ 79: 72]), .acc(arr_out[12][6] ));
  PE pe_12_7 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq19), .left_in(left_seq7 [ 35: 27]), .top_in(top_seq12[ 71: 64]), .pe_rst_seq(             ), .right_out(left_seq8 [ 35: 27]), .bottom_out(top_seq13[ 71: 64]), .acc(arr_out[12][7] ));
  PE pe_12_8 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq20), .left_in(left_seq8 [ 35: 27]), .top_in(top_seq12[ 63: 56]), .pe_rst_seq(             ), .right_out(left_seq9 [ 35: 27]), .bottom_out(top_seq13[ 63: 56]), .acc(arr_out[12][8] ));
  PE pe_12_9 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq21), .left_in(left_seq9 [ 35: 27]), .top_in(top_seq12[ 55: 48]), .pe_rst_seq(             ), .right_out(left_seq10[ 35: 27]), .bottom_out(top_seq13[ 55: 48]), .acc(arr_out[12][9] ));
  PE pe_12_10(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq22), .left_in(left_seq10[ 35: 27]), .top_in(top_seq12[ 47: 40]), .pe_rst_seq(             ), .right_out(left_seq11[ 35: 27]), .bottom_out(top_seq13[ 47: 40]), .acc(arr_out[12][10]));
  PE pe_12_11(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq23), .left_in(left_seq11[ 35: 27]), .top_in(top_seq12[ 39: 32]), .pe_rst_seq(             ), .right_out(left_seq12[ 35: 27]), .bottom_out(top_seq13[ 39: 32]), .acc(arr_out[12][11]));
  PE pe_12_12(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq24), .left_in(left_seq12[ 35: 27]), .top_in(top_seq12[ 31: 24]), .pe_rst_seq(             ), .right_out(left_seq13[ 35: 27]), .bottom_out(top_seq13[ 31: 24]), .acc(arr_out[12][12]));
  PE pe_12_13(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq25), .left_in(left_seq13[ 35: 27]), .top_in(top_seq12[ 23: 16]), .pe_rst_seq(             ), .right_out(left_seq14[ 35: 27]), .bottom_out(top_seq13[ 23: 16]), .acc(arr_out[12][13]));
  PE pe_12_14(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq26), .left_in(left_seq14[ 35: 27]), .top_in(top_seq12[ 15:  8]), .pe_rst_seq(             ), .right_out(left_seq15[ 35: 27]), .bottom_out(top_seq13[ 15:  8]), .acc(arr_out[12][14]));
  PE pe_12_15(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq27), .left_in(left_seq15[ 35: 27]), .top_in(top_seq12[  7:  0]), .pe_rst_seq(sys_rst_seq28), .right_out(     right[ 35: 27]), .bottom_out(top_seq13[  7:  0]), .acc(arr_out[12][15]));
  
  PE pe_13_0 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq13), .left_in(left_seq0 [ 26: 18]), .top_in(top_seq13[127:120]), .pe_rst_seq(             ), .right_out(left_seq1 [ 26: 18]), .bottom_out(top_seq14[127:120]), .acc(arr_out[13][0] ));
  PE pe_13_1 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq14), .left_in(left_seq1 [ 26: 18]), .top_in(top_seq13[119:112]), .pe_rst_seq(             ), .right_out(left_seq2 [ 26: 18]), .bottom_out(top_seq14[119:112]), .acc(arr_out[13][1] ));
  PE pe_13_2 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq2 [ 26: 18]), .top_in(top_seq13[111:104]), .pe_rst_seq(             ), .right_out(left_seq3 [ 26: 18]), .bottom_out(top_seq14[111:104]), .acc(arr_out[13][2] ));
  PE pe_13_3 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq16), .left_in(left_seq3 [ 26: 18]), .top_in(top_seq13[103: 96]), .pe_rst_seq(             ), .right_out(left_seq4 [ 26: 18]), .bottom_out(top_seq14[103: 96]), .acc(arr_out[13][3] ));
  PE pe_13_4 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq17), .left_in(left_seq4 [ 26: 18]), .top_in(top_seq13[ 95: 88]), .pe_rst_seq(             ), .right_out(left_seq5 [ 26: 18]), .bottom_out(top_seq14[ 95: 88]), .acc(arr_out[13][4] ));
  PE pe_13_5 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq18), .left_in(left_seq5 [ 26: 18]), .top_in(top_seq13[ 87: 80]), .pe_rst_seq(             ), .right_out(left_seq6 [ 26: 18]), .bottom_out(top_seq14[ 87: 80]), .acc(arr_out[13][5] ));
  PE pe_13_6 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq19), .left_in(left_seq6 [ 26: 18]), .top_in(top_seq13[ 79: 72]), .pe_rst_seq(             ), .right_out(left_seq7 [ 26: 18]), .bottom_out(top_seq14[ 79: 72]), .acc(arr_out[13][6] ));
  PE pe_13_7 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq20), .left_in(left_seq7 [ 26: 18]), .top_in(top_seq13[ 71: 64]), .pe_rst_seq(             ), .right_out(left_seq8 [ 26: 18]), .bottom_out(top_seq14[ 71: 64]), .acc(arr_out[13][7] ));
  PE pe_13_8 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq21), .left_in(left_seq8 [ 26: 18]), .top_in(top_seq13[ 63: 56]), .pe_rst_seq(             ), .right_out(left_seq9 [ 26: 18]), .bottom_out(top_seq14[ 63: 56]), .acc(arr_out[13][8] ));
  PE pe_13_9 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq22), .left_in(left_seq9 [ 26: 18]), .top_in(top_seq13[ 55: 48]), .pe_rst_seq(             ), .right_out(left_seq10[ 26: 18]), .bottom_out(top_seq14[ 55: 48]), .acc(arr_out[13][9] ));
  PE pe_13_10(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq23), .left_in(left_seq10[ 26: 18]), .top_in(top_seq13[ 47: 40]), .pe_rst_seq(             ), .right_out(left_seq11[ 26: 18]), .bottom_out(top_seq14[ 47: 40]), .acc(arr_out[13][10]));
  PE pe_13_11(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq24), .left_in(left_seq11[ 26: 18]), .top_in(top_seq13[ 39: 32]), .pe_rst_seq(             ), .right_out(left_seq12[ 26: 18]), .bottom_out(top_seq14[ 39: 32]), .acc(arr_out[13][11]));
  PE pe_13_12(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq25), .left_in(left_seq12[ 26: 18]), .top_in(top_seq13[ 31: 24]), .pe_rst_seq(             ), .right_out(left_seq13[ 26: 18]), .bottom_out(top_seq14[ 31: 24]), .acc(arr_out[13][12]));
  PE pe_13_13(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq26), .left_in(left_seq13[ 26: 18]), .top_in(top_seq13[ 23: 16]), .pe_rst_seq(             ), .right_out(left_seq14[ 26: 18]), .bottom_out(top_seq14[ 23: 16]), .acc(arr_out[13][13]));
  PE pe_13_14(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq27), .left_in(left_seq14[ 26: 18]), .top_in(top_seq13[ 15:  8]), .pe_rst_seq(             ), .right_out(left_seq15[ 26: 18]), .bottom_out(top_seq14[ 15:  8]), .acc(arr_out[13][14]));
  PE pe_13_15(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq28), .left_in(left_seq15[ 26: 18]), .top_in(top_seq13[  7:  0]), .pe_rst_seq(sys_rst_seq29), .right_out(     right[ 26: 18]), .bottom_out(top_seq14[  7:  0]), .acc(arr_out[13][15]));
  
  PE pe_14_0 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq14), .left_in(left_seq0 [ 17:  9]), .top_in(top_seq14[127:120]), .pe_rst_seq(             ), .right_out(left_seq1 [ 17:  9]), .bottom_out(top_seq15[127:120]), .acc(arr_out[14][0] ));
  PE pe_14_1 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq1 [ 17:  9]), .top_in(top_seq14[119:112]), .pe_rst_seq(             ), .right_out(left_seq2 [ 17:  9]), .bottom_out(top_seq15[119:112]), .acc(arr_out[14][1] ));
  PE pe_14_2 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq16), .left_in(left_seq2 [ 17:  9]), .top_in(top_seq14[111:104]), .pe_rst_seq(             ), .right_out(left_seq3 [ 17:  9]), .bottom_out(top_seq15[111:104]), .acc(arr_out[14][2] ));
  PE pe_14_3 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq17), .left_in(left_seq3 [ 17:  9]), .top_in(top_seq14[103: 96]), .pe_rst_seq(             ), .right_out(left_seq4 [ 17:  9]), .bottom_out(top_seq15[103: 96]), .acc(arr_out[14][3] ));
  PE pe_14_4 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq18), .left_in(left_seq4 [ 17:  9]), .top_in(top_seq14[ 95: 88]), .pe_rst_seq(             ), .right_out(left_seq5 [ 17:  9]), .bottom_out(top_seq15[ 95: 88]), .acc(arr_out[14][4] ));
  PE pe_14_5 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq19), .left_in(left_seq5 [ 17:  9]), .top_in(top_seq14[ 87: 80]), .pe_rst_seq(             ), .right_out(left_seq6 [ 17:  9]), .bottom_out(top_seq15[ 87: 80]), .acc(arr_out[14][5] ));
  PE pe_14_6 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq20), .left_in(left_seq6 [ 17:  9]), .top_in(top_seq14[ 79: 72]), .pe_rst_seq(             ), .right_out(left_seq7 [ 17:  9]), .bottom_out(top_seq15[ 79: 72]), .acc(arr_out[14][6] ));
  PE pe_14_7 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq21), .left_in(left_seq7 [ 17:  9]), .top_in(top_seq14[ 71: 64]), .pe_rst_seq(             ), .right_out(left_seq8 [ 17:  9]), .bottom_out(top_seq15[ 71: 64]), .acc(arr_out[14][7] ));
  PE pe_14_8 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq22), .left_in(left_seq8 [ 17:  9]), .top_in(top_seq14[ 63: 56]), .pe_rst_seq(             ), .right_out(left_seq9 [ 17:  9]), .bottom_out(top_seq15[ 63: 56]), .acc(arr_out[14][8] ));
  PE pe_14_9 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq23), .left_in(left_seq9 [ 17:  9]), .top_in(top_seq14[ 55: 48]), .pe_rst_seq(             ), .right_out(left_seq10[ 17:  9]), .bottom_out(top_seq15[ 55: 48]), .acc(arr_out[14][9] ));
  PE pe_14_10(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq24), .left_in(left_seq10[ 17:  9]), .top_in(top_seq14[ 47: 40]), .pe_rst_seq(             ), .right_out(left_seq11[ 17:  9]), .bottom_out(top_seq15[ 47: 40]), .acc(arr_out[14][10]));
  PE pe_14_11(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq25), .left_in(left_seq11[ 17:  9]), .top_in(top_seq14[ 39: 32]), .pe_rst_seq(             ), .right_out(left_seq12[ 17:  9]), .bottom_out(top_seq15[ 39: 32]), .acc(arr_out[14][11]));
  PE pe_14_12(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq26), .left_in(left_seq12[ 17:  9]), .top_in(top_seq14[ 31: 24]), .pe_rst_seq(             ), .right_out(left_seq13[ 17:  9]), .bottom_out(top_seq15[ 31: 24]), .acc(arr_out[14][12]));
  PE pe_14_13(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq27), .left_in(left_seq13[ 17:  9]), .top_in(top_seq14[ 23: 16]), .pe_rst_seq(             ), .right_out(left_seq14[ 17:  9]), .bottom_out(top_seq15[ 23: 16]), .acc(arr_out[14][13]));
  PE pe_14_14(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq28), .left_in(left_seq14[ 17:  9]), .top_in(top_seq14[ 15:  8]), .pe_rst_seq(             ), .right_out(left_seq15[ 17:  9]), .bottom_out(top_seq15[ 15:  8]), .acc(arr_out[14][14]));
  PE pe_14_15(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq29), .left_in(left_seq15[ 17:  9]), .top_in(top_seq14[  7:  0]), .pe_rst_seq(sys_rst_seq30), .right_out(     right[ 17:  9]), .bottom_out(top_seq15[  7:  0]), .acc(arr_out[14][15]));
  
  PE pe_15_0 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq0 [  8:  0]), .top_in(top_seq15[127:120]), .pe_rst_seq(             ), .right_out(left_seq1 [  8:  0]), .bottom_out(   bottom[127:120]), .acc(arr_out[15][0] ));
  PE pe_15_1 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq16), .left_in(left_seq1 [  8:  0]), .top_in(top_seq15[119:112]), .pe_rst_seq(             ), .right_out(left_seq2 [  8:  0]), .bottom_out(   bottom[119:112]), .acc(arr_out[15][1] ));
  PE pe_15_2 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq17), .left_in(left_seq2 [  8:  0]), .top_in(top_seq15[111:104]), .pe_rst_seq(             ), .right_out(left_seq3 [  8:  0]), .bottom_out(   bottom[111:104]), .acc(arr_out[15][2] ));
  PE pe_15_3 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq18), .left_in(left_seq3 [  8:  0]), .top_in(top_seq15[103: 96]), .pe_rst_seq(             ), .right_out(left_seq4 [  8:  0]), .bottom_out(   bottom[103: 96]), .acc(arr_out[15][3] ));
  PE pe_15_4 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq19), .left_in(left_seq4 [  8:  0]), .top_in(top_seq15[ 95: 88]), .pe_rst_seq(             ), .right_out(left_seq5 [  8:  0]), .bottom_out(   bottom[ 95: 88]), .acc(arr_out[15][4] ));
  PE pe_15_5 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq20), .left_in(left_seq5 [  8:  0]), .top_in(top_seq15[ 87: 80]), .pe_rst_seq(             ), .right_out(left_seq6 [  8:  0]), .bottom_out(   bottom[ 87: 80]), .acc(arr_out[15][5] ));
  PE pe_15_6 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq21), .left_in(left_seq6 [  8:  0]), .top_in(top_seq15[ 79: 72]), .pe_rst_seq(             ), .right_out(left_seq7 [  8:  0]), .bottom_out(   bottom[ 79: 72]), .acc(arr_out[15][6] ));
  PE pe_15_7 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq22), .left_in(left_seq7 [  8:  0]), .top_in(top_seq15[ 71: 64]), .pe_rst_seq(             ), .right_out(left_seq8 [  8:  0]), .bottom_out(   bottom[ 71: 64]), .acc(arr_out[15][7] ));
  PE pe_15_8 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq23), .left_in(left_seq8 [  8:  0]), .top_in(top_seq15[ 63: 56]), .pe_rst_seq(             ), .right_out(left_seq9 [  8:  0]), .bottom_out(   bottom[ 63: 56]), .acc(arr_out[15][8] ));
  PE pe_15_9 (.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq24), .left_in(left_seq9 [  8:  0]), .top_in(top_seq15[ 55: 48]), .pe_rst_seq(             ), .right_out(left_seq10[  8:  0]), .bottom_out(   bottom[ 55: 48]), .acc(arr_out[15][9] ));
  PE pe_15_10(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq25), .left_in(left_seq10[  8:  0]), .top_in(top_seq15[ 47: 40]), .pe_rst_seq(             ), .right_out(left_seq11[  8:  0]), .bottom_out(   bottom[ 47: 40]), .acc(arr_out[15][10]));
  PE pe_15_11(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq26), .left_in(left_seq11[  8:  0]), .top_in(top_seq15[ 39: 32]), .pe_rst_seq(             ), .right_out(left_seq12[  8:  0]), .bottom_out(   bottom[ 39: 32]), .acc(arr_out[15][11]));
  PE pe_15_12(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq27), .left_in(left_seq12[  8:  0]), .top_in(top_seq15[ 31: 24]), .pe_rst_seq(             ), .right_out(left_seq13[  8:  0]), .bottom_out(   bottom[ 31: 24]), .acc(arr_out[15][12]));
  PE pe_15_13(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq28), .left_in(left_seq13[  8:  0]), .top_in(top_seq15[ 23: 16]), .pe_rst_seq(             ), .right_out(left_seq14[  8:  0]), .bottom_out(   bottom[ 23: 16]), .acc(arr_out[15][13]));
  PE pe_15_14(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq29), .left_in(left_seq14[  8:  0]), .top_in(top_seq15[ 15:  8]), .pe_rst_seq(             ), .right_out(left_seq15[  8:  0]), .bottom_out(   bottom[ 15:  8]), .acc(arr_out[15][14]));
  PE pe_15_15(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq30), .left_in(left_seq15[  8:  0]), .top_in(top_seq15[  7:  0]), .pe_rst_seq(sys_rst_seq31), .right_out(     right[  8:  0]), .bottom_out(   bottom[  7:  0]), .acc(arr_out[15][15]));

  assign row0_out  = {arr_out[0][0] , arr_out[0][1] , arr_out[0][2] , arr_out[0][3] , arr_out[0][4] , arr_out[0][5] , arr_out[0][6] , arr_out[0][7] , arr_out[0][8] , arr_out[0][9] , arr_out[0][10] , arr_out[0][11] , arr_out[0][12] , arr_out[0][13] , arr_out[0][14] , arr_out[0][15] };
  assign row1_out  = {arr_out[1][0] , arr_out[1][1] , arr_out[1][2] , arr_out[1][3] , arr_out[1][4] , arr_out[1][5] , arr_out[1][6] , arr_out[1][7] , arr_out[1][8] , arr_out[1][9] , arr_out[1][10] , arr_out[1][11] , arr_out[1][12] , arr_out[1][13] , arr_out[1][14] , arr_out[1][15] };
  assign row2_out  = {arr_out[2][0] , arr_out[2][1] , arr_out[2][2] , arr_out[2][3] , arr_out[2][4] , arr_out[2][5] , arr_out[2][6] , arr_out[2][7] , arr_out[2][8] , arr_out[2][9] , arr_out[2][10] , arr_out[2][11] , arr_out[2][12] , arr_out[2][13] , arr_out[2][14] , arr_out[2][15] };
  assign row3_out  = {arr_out[3][0] , arr_out[3][1] , arr_out[3][2] , arr_out[3][3] , arr_out[3][4] , arr_out[3][5] , arr_out[3][6] , arr_out[3][7] , arr_out[3][8] , arr_out[3][9] , arr_out[3][10] , arr_out[3][11] , arr_out[3][12] , arr_out[3][13] , arr_out[3][14] , arr_out[3][15] };
  assign row4_out  = {arr_out[4][0] , arr_out[4][1] , arr_out[4][2] , arr_out[4][3] , arr_out[4][4] , arr_out[4][5] , arr_out[4][6] , arr_out[4][7] , arr_out[4][8] , arr_out[4][9] , arr_out[4][10] , arr_out[4][11] , arr_out[4][12] , arr_out[4][13] , arr_out[4][14] , arr_out[4][15] };
  assign row5_out  = {arr_out[5][0] , arr_out[5][1] , arr_out[5][2] , arr_out[5][3] , arr_out[5][4] , arr_out[5][5] , arr_out[5][6] , arr_out[5][7] , arr_out[5][8] , arr_out[5][9] , arr_out[5][10] , arr_out[5][11] , arr_out[5][12] , arr_out[5][13] , arr_out[5][14] , arr_out[5][15] };
  assign row6_out  = {arr_out[6][0] , arr_out[6][1] , arr_out[6][2] , arr_out[6][3] , arr_out[6][4] , arr_out[6][5] , arr_out[6][6] , arr_out[6][7] , arr_out[6][8] , arr_out[6][9] , arr_out[6][10] , arr_out[6][11] , arr_out[6][12] , arr_out[6][13] , arr_out[6][14] , arr_out[6][15] };
  assign row7_out  = {arr_out[7][0] , arr_out[7][1] , arr_out[7][2] , arr_out[7][3] , arr_out[7][4] , arr_out[7][5] , arr_out[7][6] , arr_out[7][7] , arr_out[7][8] , arr_out[7][9] , arr_out[7][10] , arr_out[7][11] , arr_out[7][12] , arr_out[7][13] , arr_out[7][14] , arr_out[7][15] };
  assign row8_out  = {arr_out[8][0] , arr_out[8][1] , arr_out[8][2] , arr_out[8][3] , arr_out[8][4] , arr_out[8][5] , arr_out[8][6] , arr_out[8][7] , arr_out[8][8] , arr_out[8][9] , arr_out[8][10] , arr_out[8][11] , arr_out[8][12] , arr_out[8][13] , arr_out[8][14] , arr_out[8][15] };
  assign row9_out  = {arr_out[9][0] , arr_out[9][1] , arr_out[9][2] , arr_out[9][3] , arr_out[9][4] , arr_out[9][5] , arr_out[9][6] , arr_out[9][7] , arr_out[9][8] , arr_out[9][9] , arr_out[9][10] , arr_out[9][11] , arr_out[9][12] , arr_out[9][13] , arr_out[9][14] , arr_out[9][15] };
  assign row10_out = {arr_out[10][0], arr_out[10][1], arr_out[10][2], arr_out[10][3], arr_out[10][4], arr_out[10][5], arr_out[10][6], arr_out[10][7], arr_out[10][8], arr_out[10][9], arr_out[10][10], arr_out[10][11], arr_out[10][12], arr_out[10][13], arr_out[10][14], arr_out[10][15]};
  assign row11_out = {arr_out[11][0], arr_out[11][1], arr_out[11][2], arr_out[11][3], arr_out[11][4], arr_out[11][5], arr_out[11][6], arr_out[11][7], arr_out[11][8], arr_out[11][9], arr_out[11][10], arr_out[11][11], arr_out[11][12], arr_out[11][13], arr_out[11][14], arr_out[11][15]};
  assign row12_out = {arr_out[12][0], arr_out[12][1], arr_out[12][2], arr_out[12][3], arr_out[12][4], arr_out[12][5], arr_out[12][6], arr_out[12][7], arr_out[12][8], arr_out[12][9], arr_out[12][10], arr_out[12][11], arr_out[12][12], arr_out[12][13], arr_out[12][14], arr_out[12][15]};
  assign row13_out = {arr_out[13][0], arr_out[13][1], arr_out[13][2], arr_out[13][3], arr_out[13][4], arr_out[13][5], arr_out[13][6], arr_out[13][7], arr_out[13][8], arr_out[13][9], arr_out[13][10], arr_out[13][11], arr_out[13][12], arr_out[13][13], arr_out[13][14], arr_out[13][15]};
  assign row14_out = {arr_out[14][0], arr_out[14][1], arr_out[14][2], arr_out[14][3], arr_out[14][4], arr_out[14][5], arr_out[14][6], arr_out[14][7], arr_out[14][8], arr_out[14][9], arr_out[14][10], arr_out[14][11], arr_out[14][12], arr_out[14][13], arr_out[14][14], arr_out[14][15]};
  assign row15_out = {arr_out[15][0], arr_out[15][1], arr_out[15][2], arr_out[15][3], arr_out[15][4], arr_out[15][5], arr_out[15][6], arr_out[15][7], arr_out[15][8], arr_out[15][9], arr_out[15][10], arr_out[15][11], arr_out[15][12], arr_out[15][13], arr_out[15][14], arr_out[15][15]};

  always @(posedge clk) begin
      if (!rst_n) begin
        out_valid_pp0 <= 0;
        out_valid_pp1 <= 0;
        out_valid_pp2 <= 0;
        out_valid_pp3 <= 0;
        out_valid_pp4 <= 0;
        out_valid_pp5 <= 0;
        out_valid_pp6 <= 0;
        out_valid_pp7 <= 0;
        out_valid_pp8 <= 0;
        out_valid_pp9 <= 0;
        out_valid_pp10<= 0;
        out_valid_pp11<= 0;
        out_valid_pp12<= 0;
        out_valid_pp13<= 0;
        out_valid <= 0;
      end
      else begin
        out_valid_pp0 <= in_valid;
        out_valid_pp1 <= out_valid_pp0;
        out_valid_pp2 <= out_valid_pp1;
        out_valid_pp3 <= out_valid_pp2;
        out_valid_pp4 <= out_valid_pp3;
        out_valid_pp5 <= out_valid_pp4;
        out_valid_pp6 <= out_valid_pp5;
        out_valid_pp7 <= out_valid_pp6;
        out_valid_pp8 <= out_valid_pp7;
        out_valid_pp9 <= out_valid_pp8;
        out_valid_pp10<= out_valid_pp9;
        out_valid_pp11<= out_valid_pp10;
        out_valid_pp12<= out_valid_pp11;
        out_valid_pp13<= out_valid_pp12;
        out_valid <= out_valid_pp13;
      end
  end
endmodule

/* invoke the Systolic_array_12 module
module TPU_12(
    clk,
    rst_n,
    in_valid,
    offset_valid,
    K,
    M,
    N,
    busy,
    A_wr_en,
    A_index,
    A_data_in,
    A_data_out,
    B_wr_en,
    B_index,
    B_data_in,
    B_data_out,
    C_wr_en,
    C_index,
    C_data_in,
    C_data_out
);

  input             clk;
  input             rst_n;
  input             in_valid;
  input             offset_valid;
  input [9:0]       K;
  input [10:0]      M;
  input [8:0]       N;
  output  reg       busy;
  output            A_wr_en;
  output reg [13:0] A_index;
  output [95:0]     A_data_in; //127
  input  [95:0]     A_data_out; //127
  output            B_wr_en;
  output reg [11:0] B_index;
  output [95:0]     B_data_in; //127
  input  [95:0]     B_data_out; //127
  output            C_wr_en;
  output [10:0]     C_index;
  output [383:0]    C_data_in; //511
  input  [383:0]    C_data_out; //511


  reg [383:0] data_write; //511
  
  // ========== FSM ==========
  reg [1:0] state;
  parameter IDLE = 0;
  parameter FEED = 1;
  parameter CALC = 3;
  
  // ========== Signals ==========
  reg [9:0] K_reg;
  reg [9:0] k_times;
  reg [9:0] cnt_k;
  
  reg [10:0] M_reg;
  reg [6:0] m_times, m_comb;
  reg [6:0] cnt_m;

  wire [10:0] m0 = {cnt_m, 4'h0};
  wire [10:0] m1 = {cnt_m, 4'h1};
  wire [10:0] m2 = {cnt_m, 4'h2};
  wire [10:0] m3 = {cnt_m, 4'h3};
  wire [10:0] m4 = {cnt_m, 4'h4};
  wire [10:0] m5 = {cnt_m, 4'h5};
  wire [10:0] m6 = {cnt_m, 4'h6};
  wire [10:0] m7 = {cnt_m, 4'h7};
  wire [10:0] m8 = {cnt_m, 4'h8};
  wire [10:0] m9 = {cnt_m, 4'h9};
  wire [10:0] m10= {cnt_m, 4'ha};
  wire [10:0] m11= {cnt_m, 4'hb};
  //wire [10:0] m12= {cnt_m, 4'hc};
  //wire [10:0] m13= {cnt_m, 4'hd};
  //wire [10:0] m14= {cnt_m, 4'he};
  //wire [10:0] m15= {cnt_m, 4'hf};
  
  reg [8:0] N_reg;
  reg [2:0] n_times, n_comb;
  reg [2:0] cnt_n;
  
  reg cal_rst, sys_rst;

  reg valid0, valid1, valid2, valid3, valid4, valid5, valid6, valid7, valid8, valid9, valid10, valid11; //, valid12, valid13, valid14, valid15;
  reg valid1_ff0, valid2_ff0, valid3_ff0, valid4_ff0, valid5_ff0, valid6_ff0, valid7_ff0, valid8_ff0, valid9_ff0, valid10_ff0, valid11_ff0; //, valid12_ff0, valid13_ff0, valid14_ff0, valid15_ff0;
  reg valid2_ff1, valid3_ff1, valid4_ff1, valid5_ff1, valid6_ff1, valid7_ff1, valid8_ff1, valid9_ff1, valid10_ff1, valid11_ff1; //, valid12_ff1, valid13_ff1, valid14_ff1, valid15_ff1;
  reg valid3_ff2, valid4_ff2, valid5_ff2, valid6_ff2, valid7_ff2, valid8_ff2, valid9_ff2, valid10_ff2, valid11_ff2; //, valid12_ff2, valid13_ff2, valid14_ff2, valid15_ff2;
  reg valid4_ff3, valid5_ff3, valid6_ff3, valid7_ff3, valid8_ff3, valid9_ff3, valid10_ff3, valid11_ff3; //, valid12_ff3, valid13_ff3, valid14_ff3, valid15_ff3;
  reg valid5_ff4, valid6_ff4, valid7_ff4, valid8_ff4, valid9_ff4, valid10_ff4, valid11_ff4; //, valid12_ff4, valid13_ff4, valid14_ff4, valid15_ff4;
  reg valid6_ff5, valid7_ff5, valid8_ff5, valid9_ff5, valid10_ff5, valid11_ff5; //, valid12_ff5, valid13_ff5, valid14_ff5, valid15_ff5;
  reg valid7_ff6, valid8_ff6, valid9_ff6, valid10_ff6, valid11_ff6; //, valid12_ff6, valid13_ff6, valid14_ff6, valid15_ff6;
  reg valid8_ff7, valid9_ff7, valid10_ff7, valid11_ff7; //, valid12_ff7, valid13_ff7, valid14_ff7, valid15_ff7;
  reg valid9_ff8, valid10_ff8, valid11_ff8; //, valid12_ff8, valid13_ff8, valid14_ff8, valid15_ff8;
  reg valid10_ff9, valid11_ff9; //, valid12_ff9, valid13_ff9, valid14_ff9, valid15_ff9;
  reg valid11_ff10; //, valid12_ff10, valid13_ff10, valid14_ff10, valid15_ff10;
  //reg valid12_ff11, valid13_ff11, valid14_ff11, valid15_ff11;
  //reg valid13_ff12, valid14_ff12, valid15_ff12;
  //reg valid14_ff13, valid15_ff13;
  //reg valid15_ff14;
  
  reg [7:0] row0, row1, row2, row3, row4, row5, row6, row7, row8, row9, row10, row11; //, row12, row13, row14, row15;
  reg [7:0] row1_ff0, row2_ff0, row3_ff0, row4_ff0, row5_ff0, row6_ff0, row7_ff0, row8_ff0, row9_ff0, row10_ff0, row11_ff0; //, row12_ff0, row13_ff0, row14_ff0, row15_ff0;
  reg [7:0] row2_ff1, row3_ff1, row4_ff1, row5_ff1, row6_ff1, row7_ff1, row8_ff1, row9_ff1, row10_ff1, row11_ff1; //, row12_ff1, row13_ff1, row14_ff1, row15_ff1;
  reg [7:0] row3_ff2, row4_ff2, row5_ff2, row6_ff2, row7_ff2, row8_ff2, row9_ff2, row10_ff2, row11_ff2; //, row12_ff2, row13_ff2, row14_ff2, row15_ff2;
  reg [7:0] row4_ff3, row5_ff3, row6_ff3, row7_ff3, row8_ff3, row9_ff3, row10_ff3, row11_ff3; //, row12_ff3, row13_ff3, row14_ff3, row15_ff3;
  reg [7:0] row5_ff4, row6_ff4, row7_ff4, row8_ff4, row9_ff4, row10_ff4, row11_ff4; //, row12_ff4, row13_ff4, row14_ff4, row15_ff4;
  reg [7:0] row6_ff5, row7_ff5, row8_ff5, row9_ff5, row10_ff5, row11_ff5; //, row12_ff5, row13_ff5, row14_ff5, row15_ff5;
  reg [7:0] row7_ff6, row8_ff6, row9_ff6, row10_ff6, row11_ff6; //, row12_ff6, row13_ff6, row14_ff6, row15_ff6;
  reg [7:0] row8_ff7, row9_ff7, row10_ff7, row11_ff7; //, row12_ff7, row13_ff7, row14_ff7, row15_ff7;
  reg [7:0] row9_ff8, row10_ff8, row11_ff8; //, row12_ff8, row13_ff8, row14_ff8, row15_ff8;
  reg [7:0] row10_ff9, row11_ff9; //, row12_ff9, row13_ff9, row14_ff9, row15_ff9;
  reg [7:0] row11_ff10; //, row12_ff10, row13_ff10, row14_ff10, row15_ff10;
  //reg [7:0] row12_ff11, row13_ff11, row14_ff11, row15_ff11;
  //reg [7:0] row13_ff12, row14_ff12, row15_ff12;
  //reg [7:0] row14_ff13, row15_ff13;
  //reg [7:0] row15_ff14;
  
  reg [7:0] col0, col1, col2, col3, col4, col5, col6, col7, col8, col9, col10, col11; //, col12, col13, col14, col15;
  reg [7:0] col1_ff0, col2_ff0, col3_ff0, col4_ff0, col5_ff0, col6_ff0, col7_ff0, col8_ff0, col9_ff0, col10_ff0, col11_ff0; //, col12_ff0, col13_ff0, col14_ff0, col15_ff0;
  reg [7:0] col2_ff1, col3_ff1, col4_ff1, col5_ff1, col6_ff1, col7_ff1, col8_ff1, col9_ff1, col10_ff1, col11_ff1; //, col12_ff1, col13_ff1, col14_ff1, col15_ff1;
  reg [7:0] col3_ff2, col4_ff2, col5_ff2, col6_ff2, col7_ff2, col8_ff2, col9_ff2, col10_ff2, col11_ff2; //, col12_ff2, col13_ff2, col14_ff2, col15_ff2;
  reg [7:0] col4_ff3, col5_ff3, col6_ff3, col7_ff3, col8_ff3, col9_ff3, col10_ff3, col11_ff3; //, col12_ff3, col13_ff3, col14_ff3, col15_ff3;
  reg [7:0] col5_ff4, col6_ff4, col7_ff4, col8_ff4, col9_ff4, col10_ff4, col11_ff4; //, col12_ff4, col13_ff4, col14_ff4, col15_ff4;
  reg [7:0] col6_ff5, col7_ff5, col8_ff5, col9_ff5, col10_ff5, col11_ff5; //, col12_ff5, col13_ff5, col14_ff5, col15_ff5;
  reg [7:0] col7_ff6, col8_ff6, col9_ff6, col10_ff6, col11_ff6; //, col12_ff6, col13_ff6, col14_ff6, col15_ff6;
  reg [7:0] col8_ff7, col9_ff7, col10_ff7, col11_ff7; //, col12_ff7, col13_ff7, col14_ff7, col15_ff7;
  reg [7:0] col9_ff8, col10_ff8, col11_ff8; //, col12_ff8, col13_ff8, col14_ff8, col15_ff8;
  reg [7:0] col10_ff9, col11_ff9; //, col12_ff9, col13_ff9, col14_ff9, col15_ff9;
  reg [7:0] col11_ff10; //, col12_ff10, col13_ff10, col14_ff10, col15_ff10;
  //reg [7:0] col12_ff11, col13_ff11, col14_ff11, col15_ff11;
  //reg [7:0] col13_ff12, col14_ff12, col15_ff12;
  //reg [7:0] col14_ff13, col15_ff13;
  //reg [7:0] col15_ff14;

  reg [11:0] valid_bus; //15
  reg [95:0] a_bus, b_bus; //127
  wire [11:0] out_valid; //15
  wire [383:0] result0, result1, result2, result3, result4, result5, result6, result7, result8, result9, result10, result11; //, result12, result13, result14, result15;  //511

  wire eq_k, eq_m, eq_n;
  reg grabbing;
  wire end_feeding;
  wire end_calculating;
  
  reg eq_k_ff0, eq_k_ff1;
  reg r0_done, r1_done, r2_done, r3_done, r4_done, r5_done, r6_done, r7_done, r8_done, r9_done, r10_done, r11_done; //, r12_done, r13_done, r14_done, r15_done;
  reg [11:0] idx_c; //15
  wire [11:0] write_valid; //15


  // ========== State ==========
  always @(posedge clk) begin
    if (!rst_n) state <= IDLE;
    else begin
        case (state)
        IDLE:   state <= in_valid ? FEED : IDLE;
        FEED:   state <= end_feeding ? CALC : FEED;
        CALC:   state <= end_calculating ? IDLE : CALC;
        endcase
    end
  end

  // ========== Registers ==========
  always @(posedge clk) begin
    if (!rst_n) begin
      K_reg <= 0;
      M_reg <= 0;
      N_reg <= 0;
    end
    else begin
      K_reg <= in_valid ? K : K_reg;
      M_reg <= in_valid ? M : M_reg;
      N_reg <= in_valid ? N : N_reg;
    end
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      k_times <= 0;
      m_times <= 0;
      n_times <= 0;
    end
    else begin
      if (in_valid) begin
          k_times <= K + 14;
          m_times <= M[3:0] == 4'h0 ? (M[10:4] - 1) : M[10:4];
          n_times <= N[3:0] == 4'h0 ? (N[ 8:4] - 1) : N[ 8:4];
      end
      else begin
          k_times <= k_times;
          m_times <= m_times;
          n_times <= n_times;
      end
    end
  end

  // ========== SRAM interface ==========
  // Buffer A
  assign A_wr_en = 0;
  assign A_data_in = 0;
  
  // Buffer B
  assign B_wr_en = 0;
  assign B_data_in = 0;
  
  // Buffer C
  //assign write_valid = {(r0_done & out_valid[15]), (r1_done & out_valid[14]), (r2_done & out_valid[13]), (r3_done & out_valid[12]), (r4_done & out_valid[11]), (r5_done & out_valid[10]), (r6_done & out_valid[9]), (r7_done & out_valid[8]), (r8_done & out_valid[7]), (r9_done & out_valid[6]), (r10_done & out_valid[5]), (r11_done & out_valid[4]), (r12_done & out_valid[3]), (r13_done & out_valid[2]), (r14_done & out_valid[1]), (r15_done & out_valid[0])};
  assign write_valid = {(r0_done & out_valid[11]), (r1_done & out_valid[10]), (r2_done & out_valid[9]), (r3_done & out_valid[8]), (r4_done & out_valid[7]), (r5_done & out_valid[6]), (r6_done & out_valid[5]), (r7_done & out_valid[4]), (r8_done & out_valid[3]), (r9_done & out_valid[2]), (r10_done & out_valid[1]), (r11_done & out_valid[0]) };
  assign C_wr_en = |write_valid;
  assign C_index = |write_valid ? idx_c : 0;
  assign C_data_in = data_write;
  
  always @(*) begin
    if (write_valid[11]) 
      data_write = result0;
    else if (write_valid[10]) 
      data_write = result1;
    else if (write_valid[9]) 
      data_write = result2;
    else if (write_valid[8]) 
      data_write = result3;
    else if (write_valid[7]) 
      data_write = result4;
    else if (write_valid[6]) 
      data_write = result5;
    else if (write_valid[5]) 
      data_write = result6;
    else if (write_valid[4]) 
      data_write = result7;
    else if (write_valid[3]) 
      data_write = result8;
    else if (write_valid[2]) 
      data_write = result9;
    else if (write_valid[1]) 
      data_write = result10;
    else if (write_valid[0]) 
      data_write = result11;
    else data_write = 'd0;
  end

  // ========== Design ==========
  assign eq_k = cnt_k == k_times;
  assign eq_m = cnt_m == m_times;
  assign eq_n = cnt_n == n_times;
  assign end_feeding = eq_k & eq_m & eq_n;
  assign end_calculating = idx_c == M_reg * (n_times + 1);
  
  always @(*) begin
    if (state == FEED) 
      grabbing = cnt_k < K_reg;
    else 
      grabbing = 0;
  end
  
  always @(posedge clk) begin
    if (!rst_n) begin
      cnt_k <= 0;
      cnt_m <= 0;
      cnt_n <= 0;
      A_index <= 0;
      B_index <= 0;
    end
    else begin
    if (in_valid) begin
      cnt_k <= 0;
      cnt_m <= 0;
      cnt_n <= 0;
      A_index <= 0;
      B_index <= 0;
    end
    else if (eq_k & eq_m & eq_n) begin
      cnt_k <= cnt_k;
      cnt_m <= cnt_m;
      cnt_n <= cnt_n;
      A_index <= A_index;
      B_index <= B_index;
    end
    else if (eq_k & eq_m) begin
      cnt_k <= 0;
      cnt_m <= 0;
      cnt_n <= cnt_n + 1;
      A_index <= 0;
      B_index <= B_index + 1;
    end
    else if (eq_k) begin
      cnt_k <= 0;
      cnt_m <= cnt_m + 1;
      cnt_n <= cnt_n;
      A_index <= A_index + 1;
      B_index <= B_index - (K_reg - 1);
    end
    else begin
      cnt_k <= cnt_k + 1;
      cnt_m <= cnt_m;
      cnt_n <= cnt_n;
      A_index <= cnt_k < K_reg-1 ? A_index + 1 : A_index;
      B_index <= cnt_k < K_reg-1 ? B_index + 1 : B_index;
    end
    end
  end
  
  always @(*) begin
    cal_rst = cnt_k == 0 ? 1 : 0;

    valid0 = (m0 < M_reg) ? 1 : 0;
    valid1 = (m1 < M_reg) ? 1 : 0;
    valid2 = (m2 < M_reg) ? 1 : 0;
    valid3 = (m3 < M_reg) ? 1 : 0;
    valid4 = (m4 < M_reg) ? 1 : 0;
    valid5 = (m5 < M_reg) ? 1 : 0;
    valid6 = (m6 < M_reg) ? 1 : 0;
    valid7 = (m7 < M_reg) ? 1 : 0;
    valid8 = (m8 < M_reg) ? 1 : 0;
    valid9 = (m9 < M_reg) ? 1 : 0;
    valid10= (m10< M_reg) ? 1 : 0;
    valid11= (m11< M_reg) ? 1 : 0;
    //valid12= (m12< M_reg) ? 1 : 0;
    //valid13= (m13< M_reg) ? 1 : 0;
    //valid14= (m14< M_reg) ? 1 : 0;
    //valid15= (m15< M_reg) ? 1 : 0;
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      valid1_ff0 <= 0;  valid2_ff0 <= 0;   valid3_ff0 <= 0;  valid4_ff0 <= 0;  valid5_ff0 <= 0;  valid6_ff0 <= 0;  valid7_ff0 <= 0;  valid8_ff0 <= 0;  valid9_ff0 <= 0;  valid10_ff0 <= 0; valid11_ff0 <= 0; //valid12_ff0 <= 0; valid13_ff0 <= 0; valid14_ff0 <= 0; valid15_ff0 <= 0;
      valid2_ff1 <= 0;  valid3_ff1 <= 0;   valid4_ff1 <= 0;  valid5_ff1 <= 0;  valid6_ff1 <= 0;  valid7_ff1 <= 0;  valid8_ff1 <= 0;  valid9_ff1 <= 0;  valid10_ff1 <= 0; valid11_ff1 <= 0; //valid12_ff1 <= 0; valid13_ff1 <= 0; valid14_ff1 <= 0; valid15_ff1 <= 0;
      valid3_ff2 <= 0;  valid4_ff2 <= 0;   valid5_ff2 <= 0;  valid6_ff2 <= 0;  valid7_ff2 <= 0;  valid8_ff2 <= 0;  valid9_ff2 <= 0;  valid10_ff2 <= 0; valid11_ff2 <= 0; //valid12_ff2 <= 0; valid13_ff2 <= 0; valid14_ff2 <= 0; valid15_ff2 <= 0;
      valid4_ff3 <= 0;  valid5_ff3 <= 0;   valid6_ff3 <= 0;  valid7_ff3 <= 0;  valid8_ff3 <= 0;  valid9_ff3 <= 0;  valid10_ff3 <= 0; valid11_ff3 <= 0; //valid12_ff3 <= 0; valid13_ff3 <= 0; valid14_ff3 <= 0; valid15_ff3 <= 0;
      valid5_ff4 <= 0;  valid6_ff4 <= 0;   valid7_ff4 <= 0;  valid8_ff4 <= 0;  valid9_ff4 <= 0;  valid10_ff4 <= 0; valid11_ff4 <= 0; //valid12_ff4 <= 0; valid13_ff4 <= 0; valid14_ff4 <= 0; valid15_ff4 <= 0;
      valid6_ff5 <= 0;  valid7_ff5 <= 0;   valid8_ff5 <= 0;  valid9_ff5 <= 0;  valid10_ff5 <= 0; valid11_ff5 <= 0; //valid12_ff5 <= 0; valid13_ff5 <= 0; valid14_ff5 <= 0; valid15_ff5 <= 0;
      valid7_ff6 <= 0;  valid8_ff6 <= 0;   valid9_ff6 <= 0;  valid10_ff6 <= 0; valid11_ff6 <= 0; //valid12_ff6 <= 0; valid13_ff6 <= 0; valid14_ff6 <= 0; valid15_ff6 <= 0;
      valid8_ff7 <= 0;  valid9_ff7 <= 0;   valid10_ff7 <= 0; valid11_ff7 <= 0; //valid12_ff7 <= 0; valid13_ff7 <= 0; valid14_ff7 <= 0; valid15_ff7 <= 0;
      valid9_ff8 <= 0;  valid10_ff8 <= 0;  valid11_ff8 <= 0; //valid12_ff8 <= 0; valid13_ff8 <= 0; valid14_ff8 <= 0; valid15_ff8 <= 0;
      valid10_ff9 <= 0; valid11_ff9 <= 0;  //valid12_ff9 <= 0; valid13_ff9 <= 0; valid14_ff9 <= 0; valid15_ff9 <= 0;
      valid11_ff10<= 0; //valid12_ff10<= 0;  valid13_ff10<= 0; valid14_ff10<= 0; valid15_ff10<= 0;
      //valid12_ff11<= 0; valid13_ff11<= 0;  valid14_ff11<= 0; valid15_ff11<= 0;
      //valid13_ff12<= 0; valid14_ff12<= 0;  valid15_ff12<= 0;
      //valid14_ff13<= 0; valid15_ff13<= 0;
      //valid15_ff14<= 0;
    end
    else begin
      valid1_ff0 <= valid1;        valid2_ff0 <= valid2;        valid3_ff0 <= valid3;        valid4_ff0 <= valid4;       valid5_ff0 <= valid5;       valid6_ff0 <= valid6;       valid7_ff0 <= valid7;       valid8_ff0 <= valid8;       valid9_ff0 <= valid9;       valid10_ff0 <= valid10;     valid11_ff0 <= valid11;     //valid12_ff0 <= valid12;     valid13_ff0 <= valid13;     valid14_ff0 <= valid14;     valid15_ff0 <= valid15;
      valid2_ff1 <= valid2_ff0;    valid3_ff1 <= valid3_ff0;    valid4_ff1 <= valid4_ff0;    valid5_ff1 <= valid5_ff0;   valid6_ff1 <= valid6_ff0;   valid7_ff1 <= valid7_ff0;   valid8_ff1 <= valid8_ff0;   valid9_ff1 <= valid9_ff0;   valid10_ff1 <= valid10_ff0; valid11_ff1 <= valid11_ff0; //valid12_ff1 <= valid12_ff0; valid13_ff1 <= valid13_ff0; valid14_ff1 <= valid14_ff0; valid15_ff1 <= valid15_ff0;
      valid3_ff2 <= valid3_ff1;    valid4_ff2 <= valid4_ff1;    valid5_ff2 <= valid5_ff1;    valid6_ff2 <= valid6_ff1;   valid7_ff2 <= valid7_ff1;   valid8_ff2 <= valid8_ff1;   valid9_ff2 <= valid9_ff1;   valid10_ff2 <= valid10_ff1; valid11_ff2 <= valid11_ff1; //valid12_ff2 <= valid12_ff1; valid13_ff2 <= valid13_ff1; valid14_ff2 <= valid14_ff1; valid15_ff2 <= valid15_ff1;
      valid4_ff3 <= valid4_ff2;    valid5_ff3 <= valid5_ff2;    valid6_ff3 <= valid6_ff2;    valid7_ff3 <= valid7_ff2;   valid8_ff3 <= valid8_ff2;   valid9_ff3 <= valid9_ff2;   valid10_ff3 <= valid10_ff2; valid11_ff3 <= valid11_ff2; //valid12_ff3 <= valid12_ff2; valid13_ff3 <= valid13_ff2; valid14_ff3 <= valid14_ff2; valid15_ff3 <= valid15_ff2;
      valid5_ff4 <= valid5_ff3;    valid6_ff4 <= valid6_ff3;    valid7_ff4 <= valid7_ff3;    valid8_ff4 <= valid8_ff3;   valid9_ff4 <= valid9_ff3;   valid10_ff4 <= valid10_ff3; valid11_ff4 <= valid11_ff3; //valid12_ff4 <= valid12_ff3; valid13_ff4 <= valid13_ff3; valid14_ff4 <= valid14_ff3; valid15_ff4 <= valid15_ff3;
      valid6_ff5 <= valid6_ff4;    valid7_ff5 <= valid7_ff4;    valid8_ff5 <= valid8_ff4;    valid9_ff5 <= valid9_ff4;   valid10_ff5 <= valid10_ff4; valid11_ff5 <= valid11_ff4; //valid12_ff5 <= valid12_ff4; valid13_ff5 <= valid13_ff4; valid14_ff5 <= valid14_ff4; valid15_ff5 <= valid15_ff4;
      valid7_ff6 <= valid7_ff5;    valid8_ff6 <= valid8_ff5;    valid9_ff6 <= valid9_ff5;    valid10_ff6 <= valid10_ff5; valid11_ff6 <= valid11_ff5; //valid12_ff6 <= valid12_ff5; valid13_ff6 <= valid13_ff5; valid14_ff6 <= valid14_ff5; valid15_ff6 <= valid15_ff5;
      valid8_ff7 <= valid8_ff6;    valid9_ff7 <= valid9_ff6;    valid10_ff7 <= valid10_ff6;  valid11_ff7 <= valid11_ff6; //valid12_ff7 <= valid12_ff6; valid13_ff7 <= valid13_ff6; valid14_ff7 <= valid14_ff6; valid15_ff7 <= valid15_ff6;
      valid9_ff8 <= valid9_ff7;    valid10_ff8 <= valid10_ff7;  valid11_ff8 <= valid11_ff7;  //valid12_ff8 <= valid12_ff7; valid13_ff8 <= valid13_ff7; valid14_ff8 <= valid14_ff7; valid15_ff8 <= valid15_ff7;
      valid10_ff9 <= valid10_ff8;  valid11_ff9 <= valid11_ff8;  //valid12_ff9 <= valid12_ff8;  valid13_ff9 <= valid13_ff8; valid14_ff9 <= valid14_ff8; valid15_ff9 <= valid15_ff8;
      valid11_ff10<= valid11_ff9;  //valid12_ff10<= valid12_ff9;  valid13_ff10<= valid13_ff9;  valid14_ff10<= valid14_ff9; valid15_ff10<= valid15_ff9;
      //valid12_ff11<= valid12_ff10; valid13_ff11<= valid13_ff10; valid14_ff11<= valid14_ff10; valid15_ff11<= valid15_ff10;
      //valid13_ff12<= valid13_ff11; valid14_ff12<= valid14_ff11; valid15_ff12<= valid15_ff11;
      //valid14_ff13<= valid14_ff12; valid15_ff13<= valid15_ff12;
      //valid15_ff14<= valid15_ff13;
    end
  end

  always @(*) begin
    row0 = grabbing ? A_data_out[95:88] : 0;
    row1 = grabbing ? A_data_out[87:80] : 0;
    row2 = grabbing ? A_data_out[79:72] : 0;
    row3 = grabbing ? A_data_out[71:64] : 0;
    row4 = grabbing ? A_data_out[63:56] : 0;
    row5 = grabbing ? A_data_out[55:48] : 0;
    row6 = grabbing ? A_data_out[47:40] : 0;
    row7 = grabbing ? A_data_out[39:32] : 0;
    row8 = grabbing ? A_data_out[31:24] : 0;
    row9 = grabbing ? A_data_out[23:16] : 0;
    row10= grabbing ? A_data_out[15: 8] : 0;
    row11= grabbing ? A_data_out[ 7: 0] : 0;
  
    col0 = grabbing ? B_data_out[95:88] : 0;
    col1 = grabbing ? B_data_out[87:80] : 0;
    col2 = grabbing ? B_data_out[79:72] : 0;
    col3 = grabbing ? B_data_out[71:64] : 0;
    col4 = grabbing ? B_data_out[63:56] : 0;
    col5 = grabbing ? B_data_out[55:48] : 0;
    col6= grabbing ? B_data_out[47:40] : 0;
    col7= grabbing ? B_data_out[39:32] : 0;
    col8= grabbing ? B_data_out[31:24] : 0;
    col9= grabbing ? B_data_out[23:16] : 0;
    col10= grabbing ? B_data_out[15: 8] : 0;
    col11= grabbing ? B_data_out[ 7: 0] : 0;
  end
  
  always @(posedge clk) begin
    if (!rst_n) begin
      row1_ff0 <= 0;  row2_ff0 <= 0;  row3_ff0 <= 0;  row4_ff0 <= 0;  row5_ff0 <= 0;  row6_ff0 <= 0;  row7_ff0 <= 0;  row8_ff0 <= 0;  row9_ff0 <= 0;  row10_ff0 <= 0; row11_ff0 <= 0; //row12_ff0 <= 0; row13_ff0 <= 0; row14_ff0 <= 0; row15_ff0 <= 0;
      row2_ff1 <= 0;  row3_ff1 <= 0;  row4_ff1 <= 0;  row5_ff1 <= 0;  row6_ff1 <= 0;  row7_ff1 <= 0;  row8_ff1 <= 0;  row9_ff1 <= 0;  row10_ff1 <= 0; row11_ff1 <= 0; //row12_ff1 <= 0; row13_ff1 <= 0; row14_ff1 <= 0; row15_ff1 <= 0;
      row3_ff2 <= 0;  row4_ff2 <= 0;  row5_ff2 <= 0;  row6_ff2 <= 0;  row7_ff2 <= 0;  row8_ff2 <= 0;  row9_ff2 <= 0;  row10_ff2 <= 0; row11_ff2 <= 0; //row12_ff2 <= 0; row13_ff2 <= 0; row14_ff2 <= 0; row15_ff2 <= 0;
      row4_ff3 <= 0;  row5_ff3 <= 0;  row6_ff3 <= 0;  row7_ff3 <= 0;  row8_ff3 <= 0;  row9_ff3 <= 0;  row10_ff3 <= 0; row11_ff3 <= 0; //row12_ff3 <= 0; row13_ff3 <= 0; row14_ff3 <= 0; row15_ff3 <= 0;
      row5_ff4 <= 0;  row6_ff4 <= 0;  row7_ff4 <= 0;  row8_ff4 <= 0;  row9_ff4 <= 0;  row10_ff4 <= 0; row11_ff4 <= 0; //row12_ff4 <= 0; row13_ff4 <= 0; row14_ff4 <= 0; row15_ff4 <= 0;
      row6_ff5 <= 0;  row7_ff5 <= 0;  row8_ff5 <= 0;  row9_ff5 <= 0;  row10_ff5 <= 0; row11_ff5 <= 0; //row12_ff5 <= 0; row13_ff5 <= 0; row14_ff5 <= 0; row15_ff5 <= 0;
      row7_ff6 <= 0;  row8_ff6 <= 0;  row9_ff6 <= 0;  row10_ff6 <= 0; row11_ff6 <= 0; //row12_ff6 <= 0; row13_ff6 <= 0; row14_ff6 <= 0; row15_ff6 <= 0;
      row8_ff7 <= 0;  row9_ff7 <= 0;  row10_ff7 <= 0; row11_ff7 <= 0; //row12_ff7 <= 0; row13_ff7 <= 0; row14_ff7 <= 0; row15_ff7 <= 0;
      row9_ff8 <= 0;  row10_ff8 <= 0; row11_ff8 <= 0; //row12_ff8 <= 0; row13_ff8 <= 0; row14_ff8 <= 0; row15_ff8 <= 0;
      row10_ff9 <= 0; row11_ff9 <= 0; //row12_ff9 <= 0; row13_ff9 <= 0; row14_ff9 <= 0; row15_ff9 <= 0;
      row11_ff10<= 0; //row12_ff10<= 0; row13_ff10<= 0; row14_ff10<= 0; row15_ff10<= 0;
      //row12_ff11<= 0; row13_ff11<= 0; row14_ff11<= 0; row15_ff11<= 0;
      //row13_ff12<= 0; row14_ff12<= 0; row15_ff12<= 0;
      //row14_ff13<= 0; row15_ff13<= 0;
      //row15_ff14<= 0;
  
      col1_ff0 <= 0;  col2_ff0 <= 0;  col3_ff0 <= 0;  col4_ff0 <= 0;  col5_ff0 <= 0;  col6_ff0 <= 0;  col7_ff0 <= 0;  col8_ff0 <= 0;  col9_ff0 <= 0;  col10_ff0 <= 0; col11_ff0 <= 0; //col12_ff0 <= 0; col13_ff0 <= 0; col14_ff0 <= 0; col15_ff0 <= 0;
      col2_ff1 <= 0;  col3_ff1 <= 0;  col4_ff1 <= 0;  col5_ff1 <= 0;  col6_ff1 <= 0;  col7_ff1 <= 0;  col8_ff1 <= 0;  col9_ff1 <= 0;  col10_ff1 <= 0; col11_ff1 <= 0; //col12_ff1 <= 0; col13_ff1 <= 0; col14_ff1 <= 0; col15_ff1 <= 0;
      col3_ff2 <= 0;  col4_ff2 <= 0;  col5_ff2 <= 0;  col6_ff2 <= 0;  col7_ff2 <= 0;  col8_ff2 <= 0;  col9_ff2 <= 0;  col10_ff2 <= 0; col11_ff2 <= 0; //col12_ff2 <= 0; col13_ff2 <= 0; col14_ff2 <= 0; col15_ff2 <= 0;
      col4_ff3 <= 0;  col5_ff3 <= 0;  col6_ff3 <= 0;  col7_ff3 <= 0;  col8_ff3 <= 0;  col9_ff3 <= 0;  col10_ff3 <= 0; col11_ff3 <= 0; //col12_ff3 <= 0; col13_ff3 <= 0; col14_ff3 <= 0; col15_ff3 <= 0;
      col5_ff4 <= 0;  col6_ff4 <= 0;  col7_ff4 <= 0;  col8_ff4 <= 0;  col9_ff4 <= 0;  col10_ff4 <= 0; col11_ff4 <= 0; //col12_ff4 <= 0; col13_ff4 <= 0; col14_ff4 <= 0; col15_ff4 <= 0;
      col6_ff5 <= 0;  col7_ff5 <= 0;  col8_ff5 <= 0;  col9_ff5 <= 0;  col10_ff5 <= 0; col11_ff5 <= 0; //col12_ff5 <= 0; col13_ff5 <= 0; col14_ff5 <= 0; col15_ff5 <= 0;
      col7_ff6 <= 0;  col8_ff6 <= 0;  col9_ff6 <= 0;  col10_ff6 <= 0; col11_ff6 <= 0; //col12_ff6 <= 0; col13_ff6 <= 0; col14_ff6 <= 0; col15_ff6 <= 0;
      col8_ff7 <= 0;  col9_ff7 <= 0;  col10_ff7 <= 0; col11_ff7 <= 0; //col12_ff7 <= 0; col13_ff7 <= 0; col14_ff7 <= 0; col15_ff7 <= 0;
      col9_ff8 <= 0;  col10_ff8 <= 0; col11_ff8 <= 0; //col12_ff8 <= 0; col13_ff8 <= 0; col14_ff8 <= 0; col15_ff8 <= 0;
      col10_ff9 <= 0; col11_ff9 <= 0; //col12_ff9 <= 0; col13_ff9 <= 0; col14_ff9 <= 0; col15_ff9 <= 0;
      col11_ff10<= 0; //col12_ff10<= 0; col13_ff10<= 0; col14_ff10<= 0; col15_ff10<= 0;
      //col12_ff11<= 0; col13_ff11<= 0; col14_ff11<= 0; col15_ff11<= 0;
      //col13_ff12<= 0; col14_ff12<= 0; col15_ff12<= 0;
      //col14_ff13<= 0; col15_ff13<= 0;
      //col15_ff14<= 0;
    end
    else begin
      row1_ff0 <= row1;        row2_ff0 <= row2;        row3_ff0 <= row3;        row4_ff0 <= row4;       row5_ff0 <= row5;       row6_ff0 <= row6;       row7_ff0 <= row7;       row8_ff0 <= row8;       row9_ff0 <= row9;       row10_ff0 <= row10;     row11_ff0 <= row11;     //row12_ff0 <= row12;     row13_ff0 <= row13;     row14_ff0 <= row14;     row15_ff0 <= row15;
      row2_ff1 <= row2_ff0;    row3_ff1 <= row3_ff0;    row4_ff1 <= row4_ff0;    row5_ff1 <= row5_ff0;   row6_ff1 <= row6_ff0;   row7_ff1 <= row7_ff0;   row8_ff1 <= row8_ff0;   row9_ff1 <= row9_ff0;   row10_ff1 <= row10_ff0; row11_ff1 <= row11_ff0; //row12_ff1 <= row12_ff0; row13_ff1 <= row13_ff0; row14_ff1 <= row14_ff0; row15_ff1 <= row15_ff0;
      row3_ff2 <= row3_ff1;    row4_ff2 <= row4_ff1;    row5_ff2 <= row5_ff1;    row6_ff2 <= row6_ff1;   row7_ff2 <= row7_ff1;   row8_ff2 <= row8_ff1;   row9_ff2 <= row9_ff1;   row10_ff2 <= row10_ff1; row11_ff2 <= row11_ff1; //row12_ff2 <= row12_ff1; row13_ff2 <= row13_ff1; row14_ff2 <= row14_ff1; row15_ff2 <= row15_ff1;
      row4_ff3 <= row4_ff2;    row5_ff3 <= row5_ff2;    row6_ff3 <= row6_ff2;    row7_ff3 <= row7_ff2;   row8_ff3 <= row8_ff2;   row9_ff3 <= row9_ff2;   row10_ff3 <= row10_ff2; row11_ff3 <= row11_ff2; //row12_ff3 <= row12_ff2; row13_ff3 <= row13_ff2; row14_ff3 <= row14_ff2; row15_ff3 <= row15_ff2;
      row5_ff4 <= row5_ff3;    row6_ff4 <= row6_ff3;    row7_ff4 <= row7_ff3;    row8_ff4 <= row8_ff3;   row9_ff4 <= row9_ff3;   row10_ff4 <= row10_ff3; row11_ff4 <= row11_ff3; //row12_ff4 <= row12_ff3; row13_ff4 <= row13_ff3; row14_ff4 <= row14_ff3; row15_ff4 <= row15_ff3;
      row6_ff5 <= row6_ff4;    row7_ff5 <= row7_ff4;    row8_ff5 <= row8_ff4;    row9_ff5 <= row9_ff4;   row10_ff5 <= row10_ff4; row11_ff5 <= row11_ff4; //row12_ff5 <= row12_ff4; row13_ff5 <= row13_ff4; row14_ff5 <= row14_ff4; row15_ff5 <= row15_ff4;
      row7_ff6 <= row7_ff5;    row8_ff6 <= row8_ff5;    row9_ff6 <= row9_ff5;    row10_ff6 <= row10_ff5; row11_ff6 <= row11_ff5; //row12_ff6 <= row12_ff5; row13_ff6 <= row13_ff5; row14_ff6 <= row14_ff5; row15_ff6 <= row15_ff5;
      row8_ff7 <= row8_ff6;    row9_ff7 <= row9_ff6;    row10_ff7 <= row10_ff6;  row11_ff7 <= row11_ff6; //row12_ff7 <= row12_ff6; row13_ff7 <= row13_ff6; row14_ff7 <= row14_ff6; row15_ff7 <= row15_ff6;
      row9_ff8 <= row9_ff7;    row10_ff8 <= row10_ff7;  row11_ff8 <= row11_ff7;  //row12_ff8 <= row12_ff7; row13_ff8 <= row13_ff7; row14_ff8 <= row14_ff7; row15_ff8 <= row15_ff7;
      row10_ff9 <= row10_ff8;  row11_ff9 <= row11_ff8;  //row12_ff9 <= row12_ff8;  row13_ff9 <= row13_ff8; row14_ff9 <= row14_ff8; row15_ff9 <= row15_ff8;
      row11_ff10<= row11_ff9;  //row12_ff10<= row12_ff9;  row13_ff10<= row13_ff9;  row14_ff10<= row14_ff9; row15_ff10<= row15_ff9;
      //row12_ff11<= row12_ff10; row13_ff11<= row13_ff10; row14_ff11<= row14_ff10; row15_ff11<= row15_ff10;
      //row13_ff12<= row13_ff11; row14_ff12<= row14_ff11; row15_ff12<= row15_ff11;
      //row14_ff13<= row14_ff12; row15_ff13<= row15_ff12;
      //row15_ff14<= row15_ff13;
  
      col1_ff0 <= col1;        col2_ff0 <= col2;        col3_ff0 <= col3;        col4_ff0 <= col4;       col5_ff0 <= col5;       col6_ff0 <= col6;       col7_ff0 <= col7;       col8_ff0 <= col8;       col9_ff0 <= col9;       col10_ff0 <= col10;     col11_ff0 <= col11;     //col12_ff0 <= col12;     col13_ff0 <= col13;     col14_ff0 <= col14;     col15_ff0 <= col15;
      col2_ff1 <= col2_ff0;    col3_ff1 <= col3_ff0;    col4_ff1 <= col4_ff0;    col5_ff1 <= col5_ff0;   col6_ff1 <= col6_ff0;   col7_ff1 <= col7_ff0;   col8_ff1 <= col8_ff0;   col9_ff1 <= col9_ff0;   col10_ff1 <= col10_ff0; col11_ff1 <= col11_ff0; //col12_ff1 <= col12_ff0; col13_ff1 <= col13_ff0; col14_ff1 <= col14_ff0; col15_ff1 <= col15_ff0;
      col3_ff2 <= col3_ff1;    col4_ff2 <= col4_ff1;    col5_ff2 <= col5_ff1;    col6_ff2 <= col6_ff1;   col7_ff2 <= col7_ff1;   col8_ff2 <= col8_ff1;   col9_ff2 <= col9_ff1;   col10_ff2 <= col10_ff1; col11_ff2 <= col11_ff1; //col12_ff2 <= col12_ff1; col13_ff2 <= col13_ff1; col14_ff2 <= col14_ff1; col15_ff2 <= col15_ff1;
      col4_ff3 <= col4_ff2;    col5_ff3 <= col5_ff2;    col6_ff3 <= col6_ff2;    col7_ff3 <= col7_ff2;   col8_ff3 <= col8_ff2;   col9_ff3 <= col9_ff2;   col10_ff3 <= col10_ff2; col11_ff3 <= col11_ff2; //col12_ff3 <= col12_ff2; col13_ff3 <= col13_ff2; col14_ff3 <= col14_ff2; col15_ff3 <= col15_ff2;
      col5_ff4 <= col5_ff3;    col6_ff4 <= col6_ff3;    col7_ff4 <= col7_ff3;    col8_ff4 <= col8_ff3;   col9_ff4 <= col9_ff3;   col10_ff4 <= col10_ff3; col11_ff4 <= col11_ff3; //col12_ff4 <= col12_ff3; col13_ff4 <= col13_ff3; col14_ff4 <= col14_ff3; col15_ff4 <= col15_ff3;
      col6_ff5 <= col6_ff4;    col7_ff5 <= col7_ff4;    col8_ff5 <= col8_ff4;    col9_ff5 <= col9_ff4;   col10_ff5 <= col10_ff4; col11_ff5 <= col11_ff4; //col12_ff5 <= col12_ff4; col13_ff5 <= col13_ff4; col14_ff5 <= col14_ff4; col15_ff5 <= col15_ff4;
      col7_ff6 <= col7_ff5;    col8_ff6 <= col8_ff5;    col9_ff6 <= col9_ff5;    col10_ff6 <= col10_ff5; col11_ff6 <= col11_ff5; //col12_ff6 <= col12_ff5; col13_ff6 <= col13_ff5; col14_ff6 <= col14_ff5; col15_ff6 <= col15_ff5;
      col8_ff7 <= col8_ff6;    col9_ff7 <= col9_ff6;    col10_ff7 <= col10_ff6;  col11_ff7 <= col11_ff6; //col12_ff7 <= col12_ff6; col13_ff7 <= col13_ff6; col14_ff7 <= col14_ff6; col15_ff7 <= col15_ff6;
      col9_ff8 <= col9_ff7;    col10_ff8 <= col10_ff7;  col11_ff8 <= col11_ff7;  //col12_ff8 <= col12_ff7; col13_ff8 <= col13_ff7; col14_ff8 <= col14_ff7; col15_ff8 <= col15_ff7;
      col10_ff9 <= col10_ff8;  col11_ff9 <= col11_ff8;  //col12_ff9 <= col12_ff8;  col13_ff9 <= col13_ff8; col14_ff9 <= col14_ff8; col15_ff9 <= col15_ff8;
      col11_ff10<= col11_ff9;  //col12_ff10<= col12_ff9;  col13_ff10<= col13_ff9;  col14_ff10<= col14_ff9; col15_ff10<= col15_ff9;
      //col12_ff11<= col12_ff10; col13_ff11<= col13_ff10; col14_ff11<= col14_ff10; col15_ff11<= col15_ff10;
      //col13_ff12<= col13_ff11; col14_ff12<= col14_ff11; col15_ff12<= col15_ff11;
      //col14_ff13<= col14_ff12; col15_ff13<= col15_ff12;
      //col15_ff14<= col15_ff13;
    end
  end
  
  always @(*) begin
    a_bus = {row0, row1_ff0, row2_ff1, row3_ff2, row4_ff3, row5_ff4, row6_ff5, row7_ff6, row8_ff7, row9_ff8, row10_ff9, row11_ff10 };
    b_bus = {col0, col1_ff0, col2_ff1, col3_ff2, col4_ff3, col5_ff4, col6_ff5, col7_ff6, col8_ff7, col9_ff8, col10_ff9, col11_ff10 };
    valid_bus = {valid0, valid1_ff0, valid2_ff1, valid3_ff2, valid4_ff3, valid5_ff4, valid6_ff5, valid7_ff6, valid8_ff7, valid9_ff8, valid10_ff9, valid11_ff10 };
  end


  Systolic_array_12 sys_array_12_inst ( 
    .clk(clk), 
    .rst_n(rst_n), 
    .in_valid(valid_bus), 
    .offset_valid(1'b1), 
    .sys_rst_seq0(cal_rst),   
    .left(a_bus), 
    .top(b_bus), 
    .out_valid(out_valid), 
    .row0_out(result0), 
    .row1_out(result1), 
    .row2_out(result2), 
    .row3_out(result3), 
    .row4_out(result4), 
    .row5_out(result5), 
    .row6_out(result6), 
    .row7_out(result7), 
    .row8_out(result8), 
    .row9_out(result9), 
    .row10_out(result10), 
    .row11_out(result11)
  );


  always @(posedge clk) begin
    if (!rst_n) begin
      eq_k_ff0 <= 0;
      r0_done <= 0;
      r1_done <= 0;
      r2_done <= 0;
      r3_done <= 0;
      r4_done <= 0;
      r5_done <= 0;
      r6_done <= 0;
      r7_done <= 0;
      r8_done <= 0;
      r9_done <= 0;
      r10_done <= 0;
      r11_done <= 0;
      //r12_done <= 0;
      //r13_done <= 0;
      //r14_done <= 0;
      //r15_done <= 0;
    end
    else begin
      eq_k_ff0 <= state == FEED ? eq_k : 0;
      r0_done <= in_valid ? 0 : eq_k_ff0;
      r1_done <= in_valid ? 0 : r0_done;
      r2_done <= in_valid ? 0 : r1_done;
      r3_done <= in_valid ? 0 : r2_done;
      r4_done <= in_valid ? 0 : r3_done;
      r5_done <= in_valid ? 0 : r4_done;
      r6_done <= in_valid ? 0 : r5_done;
      r7_done <= in_valid ? 0 : r6_done;
      r8_done <= in_valid ? 0 : r7_done;
      r9_done <= in_valid ? 0 : r8_done;
      r10_done <= in_valid ? 0 : r9_done;
      r11_done <= in_valid ? 0 : r10_done;
      //r12_done <= in_valid ? 0 : r11_done;
      //r13_done <= in_valid ? 0 : r12_done;
      //r14_done <= in_valid ? 0 : r13_done;
      //r15_done <= in_valid ? 0 : r14_done;
    end
  end

  always @(posedge clk) begin
    if (!rst_n) 
      idx_c <= 0;
    else begin
      if (in_valid) 
        idx_c <= 0;
      else if (|write_valid) 
        idx_c <= idx_c + 1;
      else 
        idx_c <= idx_c;
    end
  end

  always @(posedge clk) begin
    if (!rst_n) 
      busy <= 0;
    else 
      busy <= in_valid ? 1 : (end_calculating ? 0 : busy);
  end
endmodule

// 12x12
module Systolic_array_12(
    clk,
    rst_n,
    in_valid,
    offset_valid,
    sys_rst_seq0,
    left,
    top,
    out_valid,
    row0_out,
    row1_out,
    row2_out,
    row3_out,
    row4_out,
    row5_out,
    row6_out,
    row7_out,
    row8_out,
    row9_out,
    row10_out,
    row11_out
);

  input clk;
  input rst_n;
  input [11:0] in_valid; //15
  input offset_valid;
  input sys_rst_seq0;
  input [95:0] left, top; //127
  output reg [11:0] out_valid; //15
  //511
  output wire [383:0] row0_out, row1_out, row2_out, row3_out, row4_out, row5_out, row6_out, row7_out, row8_out, row9_out, row10_out, row11_out;
  
  wire sys_rst_seq1, sys_rst_seq2, sys_rst_seq3, sys_rst_seq4, sys_rst_seq5, sys_rst_seq6, sys_rst_seq7, sys_rst_seq8, sys_rst_seq9, sys_rst_seq10, sys_rst_seq11, sys_rst_seq12, sys_rst_seq13, sys_rst_seq14, sys_rst_seq15, sys_rst_seq16, sys_rst_seq17, sys_rst_seq18, sys_rst_seq19, sys_rst_seq20, sys_rst_seq21, sys_rst_seq22, sys_rst_seq23;
  
  //143
  wire [107:0] left_seq0, left_seq1, left_seq2, left_seq3, left_seq4, left_seq5, left_seq6, left_seq7, left_seq8, left_seq9, left_seq10, left_seq11, right;
  //127
  wire [95:0] top_seq1, top_seq2, top_seq3, top_seq4, top_seq5, top_seq6, top_seq7, top_seq8, top_seq9, top_seq10, top_seq11, bottom;
  
  wire signed [8:0] left_offset0 = offset_valid ? $signed(left[95:88]) + 128 : $signed(left[95:88]);
  wire signed [8:0] left_offset1 = offset_valid ? $signed(left[87:80]) + 128 : $signed(left[87:80]);
  wire signed [8:0] left_offset2 = offset_valid ? $signed(left[79:72]) + 128 : $signed(left[79:72]);
  wire signed [8:0] left_offset3 = offset_valid ? $signed(left[71:64]) + 128 : $signed(left[71:64]);
  wire signed [8:0] left_offset4 = offset_valid ? $signed(left[63:56]) + 128 : $signed(left[63:56]);
  wire signed [8:0] left_offset5 = offset_valid ? $signed(left[55:48]) + 128 : $signed(left[55:48]);
  wire signed [8:0] left_offset6 = offset_valid ? $signed(left[47:40]) + 128 : $signed(left[47:40]);
  wire signed [8:0] left_offset7 = offset_valid ? $signed(left[39:32]) + 128 : $signed(left[39:32]);
  wire signed [8:0] left_offset8 = offset_valid ? $signed(left[31:24]) + 128 : $signed(left[31:24]);
  wire signed [8:0] left_offset9 = offset_valid ? $signed(left[23:16]) + 128 : $signed(left[23:16]);
  wire signed [8:0] left_offset10= offset_valid ? $signed(left[15: 8]) + 128 : $signed(left[15: 8]);
  wire signed [8:0] left_offset11= offset_valid ? $signed(left[ 7: 0]) + 128 : $signed(left[ 7: 0]);
  assign left_seq0 = {left_offset0[8:0], left_offset1[8:0], left_offset2[8:0], left_offset3[8:0], left_offset4[8:0], left_offset5[8:0], left_offset6[8:0], left_offset7[8:0], left_offset8[8:0], left_offset9[8:0], left_offset10[8:0], left_offset11[8:0]};
  
  //15
  reg [11:0] out_valid_pp0, out_valid_pp1, out_valid_pp2, out_valid_pp3, out_valid_pp4, out_valid_pp5, out_valid_pp6, out_valid_pp7, out_valid_pp8, out_valid_pp9;
                      //15
  wire [31:0] arr_out [0:11][0:11];

  //15_15
  // Signal naming is based on 0-indexing
  PE pe_0_0(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq0),  .left_in(left_seq0[107:99]), .top_in(     top[95:88]),  .pe_rst_seq(sys_rst_seq1),  .right_out(left_seq1[107:99]), .bottom_out(top_seq1[95:88]),  .acc(arr_out[0][0]));
  PE pe_0_1(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq1),  .left_in(left_seq1[107:99]), .top_in(     top[87:80]),  .pe_rst_seq(sys_rst_seq2),  .right_out(left_seq2[107:99]), .bottom_out(top_seq1[87:80]),  .acc(arr_out[0][1]));
  PE pe_0_2(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq2),  .left_in(left_seq2[107:99]), .top_in(     top[79:72]),  .pe_rst_seq(sys_rst_seq3),  .right_out(left_seq3[107:99]), .bottom_out(top_seq1[79:72]),  .acc(arr_out[0][2]));
  PE pe_0_3(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq3),  .left_in(left_seq3[107:99]), .top_in(     top[71:64]),  .pe_rst_seq(sys_rst_seq4),  .right_out(left_seq4[107:99]), .bottom_out(top_seq1[71:64]),  .acc(arr_out[0][3]));
  PE pe_0_4(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq4),  .left_in(left_seq4[107:99]), .top_in(     top[63:56]),  .pe_rst_seq(sys_rst_seq5),  .right_out(left_seq5[107:99]), .bottom_out(top_seq1[63:56]),  .acc(arr_out[0][4]));
  PE pe_0_5(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq5),  .left_in(left_seq5[107:99]), .top_in(     top[55:48]),  .pe_rst_seq(sys_rst_seq6),  .right_out(left_seq6[107:99]), .bottom_out(top_seq1[55:48]),  .acc(arr_out[0][5]));
  PE pe_0_6(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq6),  .left_in(left_seq6[107:99]), .top_in(     top[47:40]),  .pe_rst_seq(sys_rst_seq7),  .right_out(left_seq7[107:99]), .bottom_out(top_seq1[47:40]),  .acc(arr_out[0][6]));
  PE pe_0_7(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq7),  .left_in(left_seq7[107:99]), .top_in(     top[39:32]),  .pe_rst_seq(sys_rst_seq8),  .right_out(left_seq8[107:99]), .bottom_out(top_seq1[39:32]),  .acc(arr_out[0][7]));
  PE pe_0_8(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq8),  .left_in(left_seq8[107:99]), .top_in(     top[31:24]),  .pe_rst_seq(sys_rst_seq9),  .right_out(left_seq9[107:99]), .bottom_out(top_seq1[31:24]),  .acc(arr_out[0][8]));
  PE pe_0_9(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq9),  .left_in(left_seq9[107:99]), .top_in(     top[23:16]),  .pe_rst_seq(sys_rst_seq10), .right_out(left_seq10[107:99]),.bottom_out(top_seq1[23:16]),  .acc(arr_out[0][9]));
  PE pe_0_10(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq10), .left_in(left_seq10[107:99]),.top_in(     top[15: 8]),  .pe_rst_seq(sys_rst_seq11), .right_out(left_seq11[107:99]),.bottom_out(top_seq1[15: 8]),  .acc(arr_out[0][10]));
  PE pe_0_11(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq11), .left_in(left_seq11[107:99]),.top_in(     top[ 7: 0]),  .pe_rst_seq(sys_rst_seq12), .right_out(     right[107:99]),.bottom_out(top_seq1[ 7: 0]),  .acc(arr_out[0][11]));
  
  PE pe_1_0(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq1),  .left_in(left_seq0[98:90]),  .top_in(top_seq1[95:88]),  .pe_rst_seq(            ),  .right_out(left_seq1[98:90]),  .bottom_out(top_seq2[95:88]),  .acc(arr_out[1][0]));
  PE pe_1_1(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq2),  .left_in(left_seq1[98:90]),  .top_in(top_seq1[87:80]),  .pe_rst_seq(            ),  .right_out(left_seq2[98:90]),  .bottom_out(top_seq2[87:80]),  .acc(arr_out[1][1]));
  PE pe_1_2(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq3),  .left_in(left_seq2[98:90]),  .top_in(top_seq1[79:72]),  .pe_rst_seq(            ),  .right_out(left_seq3[98:90]),  .bottom_out(top_seq2[79:72]),  .acc(arr_out[1][2]));
  PE pe_1_3(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq4),  .left_in(left_seq3[98:90]),  .top_in(top_seq1[71:64]),  .pe_rst_seq(            ),  .right_out(left_seq4[98:90]),  .bottom_out(top_seq2[71:64]),  .acc(arr_out[1][3]));
  PE pe_1_4(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq5),  .left_in(left_seq4[98:90]),  .top_in(top_seq1[63:56]),  .pe_rst_seq(            ),  .right_out(left_seq5[98:90]),  .bottom_out(top_seq2[63:56]),  .acc(arr_out[1][4]));
  PE pe_1_5(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq6),  .left_in(left_seq5[98:90]),  .top_in(top_seq1[55:48]),  .pe_rst_seq(            ),  .right_out(left_seq6[98:90]),  .bottom_out(top_seq2[55:48]),  .acc(arr_out[1][5]));
  PE pe_1_6(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq7),  .left_in(left_seq6[98:90]),  .top_in(top_seq1[47:40]),  .pe_rst_seq(            ),  .right_out(left_seq7[98:90]),  .bottom_out(top_seq2[47:40]),  .acc(arr_out[1][6]));
  PE pe_1_7(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq8),  .left_in(left_seq7[98:90]),  .top_in(top_seq1[39:32]),  .pe_rst_seq(            ),  .right_out(left_seq8[98:90]),  .bottom_out(top_seq2[39:32]),  .acc(arr_out[1][7]));
  PE pe_1_8(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq9),  .left_in(left_seq8[98:90]),  .top_in(top_seq1[31:24]),  .pe_rst_seq(             ), .right_out(left_seq9[98:90]),  .bottom_out(top_seq2[31:24]),  .acc(arr_out[1][8]));
  PE pe_1_9(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq10), .left_in(left_seq9[98:90]),  .top_in(top_seq1[23:16]),  .pe_rst_seq(             ), .right_out(left_seq10[98:90]), .bottom_out(top_seq2[23:16]),  .acc(arr_out[1][9]));
  PE pe_1_10(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq11), .left_in(left_seq10[98:90]), .top_in(top_seq1[15: 8]),  .pe_rst_seq(             ), .right_out(left_seq11[98:90]), .bottom_out(top_seq2[15: 8]),  .acc(arr_out[1][10]));
  PE pe_1_11(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq12), .left_in(left_seq11[98:90]), .top_in(top_seq1[ 7: 0]),  .pe_rst_seq(sys_rst_seq13), .right_out(     right[98:90]), .bottom_out(top_seq2[7: 0]),   .acc(arr_out[1][11]));
  
  PE pe_2_0(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq2),  .left_in(left_seq0[89:81]),  .top_in(top_seq2[95:88]),  .pe_rst_seq(            ),  .right_out(left_seq1[89:81]),  .bottom_out(top_seq3[95:88]),  .acc(arr_out[2][0]));
  PE pe_2_1(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq3),  .left_in(left_seq1[89:81]),  .top_in(top_seq2[87:80]),  .pe_rst_seq(            ),  .right_out(left_seq2[89:81]),  .bottom_out(top_seq3[87:80]),  .acc(arr_out[2][1]));
  PE pe_2_2(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq4),  .left_in(left_seq2[89:81]),  .top_in(top_seq2[79:72]),  .pe_rst_seq(            ),  .right_out(left_seq3[89:81]),  .bottom_out(top_seq3[79:72]),  .acc(arr_out[2][2]));
  PE pe_2_3(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq5),  .left_in(left_seq3[89:81]),  .top_in(top_seq2[71:64]),  .pe_rst_seq(            ),  .right_out(left_seq4[89:81]),  .bottom_out(top_seq3[71:64]),  .acc(arr_out[2][3]));
  PE pe_2_4(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq6),  .left_in(left_seq4[89:81]),  .top_in(top_seq2[63:56]),  .pe_rst_seq(            ),  .right_out(left_seq5[89:81]),  .bottom_out(top_seq3[63:56]),  .acc(arr_out[2][4]));
  PE pe_2_5(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq7),  .left_in(left_seq5[89:81]),  .top_in(top_seq2[55:48]),  .pe_rst_seq(            ),  .right_out(left_seq6[89:81]),  .bottom_out(top_seq3[55:48]),  .acc(arr_out[2][5]));
  PE pe_2_6(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq8),  .left_in(left_seq6[89:81]),  .top_in(top_seq2[47:40]),  .pe_rst_seq(            ),  .right_out(left_seq7[89:81]),  .bottom_out(top_seq3[47:40]),  .acc(arr_out[2][6]));
  PE pe_2_7(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq9),  .left_in(left_seq7[89:81]),  .top_in(top_seq2[39:32]),  .pe_rst_seq(             ), .right_out(left_seq8[89:81]),  .bottom_out(top_seq3[39:32]),  .acc(arr_out[2][7]));
  PE pe_2_8(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq10), .left_in(left_seq8[89:81]),  .top_in(top_seq2[31:24]),  .pe_rst_seq(             ), .right_out(left_seq9[89:81]),  .bottom_out(top_seq3[31:24]),  .acc(arr_out[2][8]));
  PE pe_2_9(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq11), .left_in(left_seq9[89:81]),  .top_in(top_seq2[23:16]),  .pe_rst_seq(             ), .right_out(left_seq10[89:81]), .bottom_out(top_seq3[23:16]),  .acc(arr_out[2][9]));
  PE pe_2_10(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq12), .left_in(left_seq10[89:81]), .top_in(top_seq2[15: 8]),  .pe_rst_seq(             ), .right_out(left_seq11[89:81]), .bottom_out(top_seq3[15: 8]),  .acc(arr_out[2][10]));
  PE pe_2_11(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq13), .left_in(left_seq11[89:81]), .top_in(top_seq2[ 7: 0]),  .pe_rst_seq(sys_rst_seq14), .right_out(     right[89:81]), .bottom_out(top_seq3[ 7: 0]),  .acc(arr_out[2][11]));
  
  PE pe_3_0(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq3),  .left_in(left_seq0[80:72]),  .top_in(top_seq3[95:88]),  .pe_rst_seq(            ),  .right_out(left_seq1[80:72]),  .bottom_out(top_seq4[95:88]),  .acc(arr_out[3][0]));
  PE pe_3_1(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq4),  .left_in(left_seq1[80:72]),  .top_in(top_seq3[87:80]),  .pe_rst_seq(            ),  .right_out(left_seq2[80:72]),  .bottom_out(top_seq4[87:80]),  .acc(arr_out[3][1]));
  PE pe_3_2(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq5),  .left_in(left_seq2[80:72]),  .top_in(top_seq3[79:72]),  .pe_rst_seq(            ),  .right_out(left_seq3[80:72]),  .bottom_out(top_seq4[79:72]),  .acc(arr_out[3][2]));
  PE pe_3_3(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq6),  .left_in(left_seq3[80:72]),  .top_in(top_seq3[71:64]),  .pe_rst_seq(            ),  .right_out(left_seq4[80:72]),  .bottom_out(top_seq4[71:64]),  .acc(arr_out[3][3]));
  PE pe_3_4(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq7),  .left_in(left_seq4[80:72]),  .top_in(top_seq3[63:56]),  .pe_rst_seq(            ),  .right_out(left_seq5[80:72]),  .bottom_out(top_seq4[63:56]),  .acc(arr_out[3][4]));
  PE pe_3_5(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq8),  .left_in(left_seq5[80:72]),  .top_in(top_seq3[55:48]),  .pe_rst_seq(            ),  .right_out(left_seq6[80:72]),  .bottom_out(top_seq4[55:48]),  .acc(arr_out[3][5]));
  PE pe_3_6(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq9),  .left_in(left_seq6[80:72]),  .top_in(top_seq3[47:40]),  .pe_rst_seq(             ), .right_out(left_seq7[80:72]),  .bottom_out(top_seq4[47:40]),  .acc(arr_out[3][6]));
  PE pe_3_7(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq10), .left_in(left_seq7[80:72]),  .top_in(top_seq3[39:32]),  .pe_rst_seq(             ), .right_out(left_seq8[80:72]),  .bottom_out(top_seq4[39:32]),  .acc(arr_out[3][7]));
  PE pe_3_8(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq11), .left_in(left_seq8[80:72]),  .top_in(top_seq3[31:24]),  .pe_rst_seq(             ), .right_out(left_seq9[80:72]),  .bottom_out(top_seq4[31:24]),  .acc(arr_out[3][8]));
  PE pe_3_9(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq12), .left_in(left_seq9[80:72]),  .top_in(top_seq3[23:16]),  .pe_rst_seq(             ), .right_out(left_seq10[80:72]), .bottom_out(top_seq4[23:16]),  .acc(arr_out[3][9]));
  PE pe_3_10(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq13), .left_in(left_seq10[80:72]), .top_in(top_seq3[15: 8]),  .pe_rst_seq(             ), .right_out(left_seq11[80:72]), .bottom_out(top_seq4[15: 8]),  .acc(arr_out[3][10]));
  PE pe_3_11(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq14), .left_in(left_seq11[80:72]), .top_in(top_seq3[ 7: 0]),  .pe_rst_seq(sys_rst_seq15), .right_out(     right[80:72]), .bottom_out(top_seq4[ 7: 0]),  .acc(arr_out[3][11]));
  
  PE pe_4_0(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq4),  .left_in(left_seq0[71:63]),  .top_in(top_seq4[95:88]),  .pe_rst_seq(            ),  .right_out(left_seq1[71:63]),  .bottom_out(top_seq5[95:88]),  .acc(arr_out[4][0]));
  PE pe_4_1(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq5),  .left_in(left_seq1[71:63]),  .top_in(top_seq4[87:80]),  .pe_rst_seq(            ),  .right_out(left_seq2[71:63]),  .bottom_out(top_seq5[87:80]),  .acc(arr_out[4][1]));
  PE pe_4_2(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq6),  .left_in(left_seq2[71:63]),  .top_in(top_seq4[79:72]),  .pe_rst_seq(            ),  .right_out(left_seq3[71:63]),  .bottom_out(top_seq5[79:72]),  .acc(arr_out[4][2]));
  PE pe_4_3(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq7),  .left_in(left_seq3[71:63]),  .top_in(top_seq4[71:64]),  .pe_rst_seq(            ),  .right_out(left_seq4[71:63]),  .bottom_out(top_seq5[71:64]),  .acc(arr_out[4][3]));
  PE pe_4_4(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq8),  .left_in(left_seq4[71:63]),  .top_in(top_seq4[63:56]),  .pe_rst_seq(            ),  .right_out(left_seq5[71:63]),  .bottom_out(top_seq5[63:56]),  .acc(arr_out[4][4]));
  PE pe_4_5(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq9),  .left_in(left_seq5[71:63]),  .top_in(top_seq4[55:48]),  .pe_rst_seq(            ), .right_out(left_seq6[71:63]),  .bottom_out(top_seq5[55:48]),  .acc(arr_out[4][5]));
  PE pe_4_6(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq10), .left_in(left_seq6[71:63]),  .top_in(top_seq4[47:40]),  .pe_rst_seq(            ), .right_out(left_seq7[71:63]),  .bottom_out(top_seq5[47:40]),  .acc(arr_out[4][6]));
  PE pe_4_7(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq11), .left_in(left_seq7[71:63]),  .top_in(top_seq4[39:32]),  .pe_rst_seq(            ), .right_out(left_seq8[71:63]),  .bottom_out(top_seq5[39:32]),  .acc(arr_out[4][7]));
  PE pe_4_8(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq12), .left_in(left_seq8[71:63]),  .top_in(top_seq4[31:24]),  .pe_rst_seq(            ), .right_out(left_seq9[71:63]),  .bottom_out(top_seq5[31:24]),  .acc(arr_out[4][8]));
  PE pe_4_9(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq13), .left_in(left_seq9[71:63]),  .top_in(top_seq4[23:16]),  .pe_rst_seq(            ), .right_out(left_seq10[71:63]), .bottom_out(top_seq5[23:16]),  .acc(arr_out[4][9]));
  PE pe_4_10(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq14), .left_in(left_seq10[71:63]), .top_in(top_seq4[15: 8]),  .pe_rst_seq(             ), .right_out(left_seq11[71:63]), .bottom_out(top_seq5[15: 8]),  .acc(arr_out[4][10]));
  PE pe_4_11(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq15), .left_in(left_seq11[71:63]), .top_in(top_seq4[ 7: 0]),  .pe_rst_seq(sys_rst_seq16), .right_out(     right[71:63]), .bottom_out(top_seq5[ 7: 0]),  .acc(arr_out[4][11]));
  
  PE pe_5_0(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq5),  .left_in(left_seq0[62:54]),  .top_in(top_seq5[95:88]),  .pe_rst_seq(            ),  .right_out(left_seq1[62:54]),  .bottom_out(top_seq6[95:88]),  .acc(arr_out[5][0]));
  PE pe_5_1(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq6),  .left_in(left_seq1[62:54]),  .top_in(top_seq5[87:80]),  .pe_rst_seq(            ),  .right_out(left_seq2[62:54]),  .bottom_out(top_seq6[87:80]),  .acc(arr_out[5][1]));
  PE pe_5_2(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq7),  .left_in(left_seq2[62:54]),  .top_in(top_seq5[79:72]),  .pe_rst_seq(            ),  .right_out(left_seq3[62:54]),  .bottom_out(top_seq6[79:72]),  .acc(arr_out[5][2]));
  PE pe_5_3(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq8),  .left_in(left_seq3[62:54]),  .top_in(top_seq5[71:64]),  .pe_rst_seq(            ),  .right_out(left_seq4[62:54]),  .bottom_out(top_seq6[71:64]),  .acc(arr_out[5][3]));
  PE pe_5_4(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq9),  .left_in(left_seq4[62:54]),  .top_in(top_seq5[63:56]),  .pe_rst_seq(             ), .right_out(left_seq5[62:54]),  .bottom_out(top_seq6[63:56]),  .acc(arr_out[5][4]));
  PE pe_5_5(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq10), .left_in(left_seq5[62:54]),  .top_in(top_seq5[55:48]),  .pe_rst_seq(             ), .right_out(left_seq6[62:54]),  .bottom_out(top_seq6[55:48]),  .acc(arr_out[5][5]));
  PE pe_5_6(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq11), .left_in(left_seq6[62:54]),  .top_in(top_seq5[47:40]),  .pe_rst_seq(             ), .right_out(left_seq7[62:54]),  .bottom_out(top_seq6[47:40]),  .acc(arr_out[5][6]));
  PE pe_5_7(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq12), .left_in(left_seq7[62:54]),  .top_in(top_seq5[39:32]),  .pe_rst_seq(             ), .right_out(left_seq8[62:54]),  .bottom_out(top_seq6[39:32]),  .acc(arr_out[5][7]));
  PE pe_5_8(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq13), .left_in(left_seq8[62:54]),  .top_in(top_seq5[31:24]),  .pe_rst_seq(             ), .right_out(left_seq9[62:54]),  .bottom_out(top_seq6[31:24]),  .acc(arr_out[5][8]));
  PE pe_5_9(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq14), .left_in(left_seq9[62:54]),  .top_in(top_seq5[23:16]),  .pe_rst_seq(             ), .right_out(left_seq10[62:54]), .bottom_out(top_seq6[23:16]),  .acc(arr_out[5][9]));
  PE pe_5_10(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq15), .left_in(left_seq10[62:54]), .top_in(top_seq5[15: 8]),  .pe_rst_seq(             ), .right_out(left_seq11[62:54]), .bottom_out(top_seq6[15: 8]),  .acc(arr_out[5][10]));
  PE pe_5_11(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq16), .left_in(left_seq11[62:54]), .top_in(top_seq5[ 7: 0]),  .pe_rst_seq(sys_rst_seq17), .right_out(     right[62:54]), .bottom_out(top_seq6[7: 0]),   .acc(arr_out[5][11]));
  
  PE pe_6_0(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq6),  .left_in(left_seq0[53:45]),  .top_in(top_seq6[95:88]),  .pe_rst_seq(            ),  .right_out(left_seq1[53:45]),  .bottom_out(top_seq7[95:88]),  .acc(arr_out[6][0]));
  PE pe_6_1(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq7),  .left_in(left_seq1[53:45]),  .top_in(top_seq6[87:80]),  .pe_rst_seq(            ),  .right_out(left_seq2[53:45]),  .bottom_out(top_seq7[87:80]),  .acc(arr_out[6][1]));
  PE pe_6_2(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq8),  .left_in(left_seq2[53:45]),  .top_in(top_seq6[79:72]),  .pe_rst_seq(            ),  .right_out(left_seq3[53:45]),  .bottom_out(top_seq7[79:72]),  .acc(arr_out[6][2]));
  PE pe_6_3(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq9),  .left_in(left_seq3[53:45]),  .top_in(top_seq6[71:64]),  .pe_rst_seq(             ), .right_out(left_seq4[53:45]),  .bottom_out(top_seq7[71:64]),  .acc(arr_out[6][3]));
  PE pe_6_4(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq10), .left_in(left_seq4[53:45]),  .top_in(top_seq6[63:56]),  .pe_rst_seq(             ), .right_out(left_seq5[53:45]),  .bottom_out(top_seq7[63:56]),  .acc(arr_out[6][4]));
  PE pe_6_5(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq11), .left_in(left_seq5[53:45]),  .top_in(top_seq6[55:48]),  .pe_rst_seq(             ), .right_out(left_seq6[53:45]),  .bottom_out(top_seq7[55:48]),  .acc(arr_out[6][5]));
  PE pe_6_6(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq12), .left_in(left_seq6[53:45]),  .top_in(top_seq6[47:40]),  .pe_rst_seq(             ), .right_out(left_seq7[53:45]),  .bottom_out(top_seq7[47:40]),  .acc(arr_out[6][6]));
  PE pe_6_7(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq13), .left_in(left_seq7[53:45]),  .top_in(top_seq6[39:32]),  .pe_rst_seq(             ), .right_out(left_seq8[53:45]),  .bottom_out(top_seq7[39:32]),  .acc(arr_out[6][7]));
  PE pe_6_8(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq14), .left_in(left_seq8[53:45]),  .top_in(top_seq6[31:24]),  .pe_rst_seq(             ), .right_out(left_seq9[53:45]),  .bottom_out(top_seq7[31:24]),  .acc(arr_out[6][8]));
  PE pe_6_9(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq15), .left_in(left_seq9[53:45]),  .top_in(top_seq6[23:16]),  .pe_rst_seq(             ), .right_out(left_seq10[53:45]), .bottom_out(top_seq7[23:16]),  .acc(arr_out[6][9]));
  PE pe_6_10(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq16), .left_in(left_seq10[53:45]), .top_in(top_seq6[15: 8]),  .pe_rst_seq(             ), .right_out(left_seq11[53:45]), .bottom_out(top_seq7[15: 8]),  .acc(arr_out[6][10]));
  PE pe_6_11(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq17), .left_in(left_seq11[53:45]), .top_in(top_seq6[ 7: 0]),  .pe_rst_seq(sys_rst_seq18), .right_out(     right[53:45]), .bottom_out(top_seq7[ 7: 0]),  .acc(arr_out[6][11]));
  
  PE pe_7_0(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq7),  .left_in(left_seq0[44:36]),  .top_in(top_seq7[95:88]),  .pe_rst_seq(            ),  .right_out(left_seq1[44:36]),  .bottom_out(top_seq8[95:88]),  .acc(arr_out[7][0]));
  PE pe_7_1(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq8),  .left_in(left_seq1[44:36]),  .top_in(top_seq7[87:80]),  .pe_rst_seq(            ),  .right_out(left_seq2[44:36]),  .bottom_out(top_seq8[87:80]),  .acc(arr_out[7][1]));
  PE pe_7_2(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq9),  .left_in(left_seq2[44:36]),  .top_in(top_seq7[79:72]),  .pe_rst_seq(             ), .right_out(left_seq3[44:36]),  .bottom_out(top_seq8[79:72]),  .acc(arr_out[7][2]));
  PE pe_7_3(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq10), .left_in(left_seq3[44:36]),  .top_in(top_seq7[71:64]),  .pe_rst_seq(             ), .right_out(left_seq4[44:36]),  .bottom_out(top_seq8[71:64]),  .acc(arr_out[7][3]));
  PE pe_7_4(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq11), .left_in(left_seq4[44:36]),  .top_in(top_seq7[63:56]),  .pe_rst_seq(             ), .right_out(left_seq5[44:36]),  .bottom_out(top_seq8[63:56]),  .acc(arr_out[7][4]));
  PE pe_7_5(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq12), .left_in(left_seq5[44:36]),  .top_in(top_seq7[55:48]),  .pe_rst_seq(             ), .right_out(left_seq6[44:36]),  .bottom_out(top_seq8[55:48]),  .acc(arr_out[7][5]));
  PE pe_7_6(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq13), .left_in(left_seq6[44:36]),  .top_in(top_seq7[47:40]),  .pe_rst_seq(             ), .right_out(left_seq7[44:36]),  .bottom_out(top_seq8[47:40]),  .acc(arr_out[7][6]));
  PE pe_7_7(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq14), .left_in(left_seq7[44:36]),  .top_in(top_seq7[39:32]),  .pe_rst_seq(             ), .right_out(left_seq8[44:36]),  .bottom_out(top_seq8[39:32]),  .acc(arr_out[7][7]));
  PE pe_7_8(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq15), .left_in(left_seq8[44:36]),  .top_in(top_seq7[31:24]),  .pe_rst_seq(             ), .right_out(left_seq9[44:36]),  .bottom_out(top_seq8[31:24]),  .acc(arr_out[7][8]));
  PE pe_7_9(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq16), .left_in(left_seq9[44:36]),  .top_in(top_seq7[23:16]),  .pe_rst_seq(             ), .right_out(left_seq10[44:36]), .bottom_out(top_seq8[23:16]),  .acc(arr_out[7][9]));
  PE pe_7_10(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq17), .left_in(left_seq10[44:36]), .top_in(top_seq7[15: 8]),  .pe_rst_seq(             ), .right_out(left_seq11[44:36]), .bottom_out(top_seq8[15: 8]),  .acc(arr_out[7][10]));
  PE pe_7_11(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq18), .left_in(left_seq11[44:36]), .top_in(top_seq7[ 7: 0]),  .pe_rst_seq(sys_rst_seq19), .right_out(     right[44:36]), .bottom_out(top_seq8[ 7: 0]),  .acc(arr_out[7][11]));
  
  PE pe_8_0(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq8),  .left_in(left_seq0[35:27]),  .top_in(top_seq8[95:88]),  .pe_rst_seq(             ),  .right_out(left_seq1[35:27]),  .bottom_out(top_seq9[95:88]),  .acc(arr_out[8][0]));
  PE pe_8_1(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq9),  .left_in(left_seq1[35:27]),  .top_in(top_seq8[87:80]),  .pe_rst_seq(             ), .right_out(left_seq2[35:27]),  .bottom_out(top_seq9[87:80]),  .acc(arr_out[8][1]));
  PE pe_8_2(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq10), .left_in(left_seq2[35:27]),  .top_in(top_seq8[79:72]),  .pe_rst_seq(             ), .right_out(left_seq3[35:27]),  .bottom_out(top_seq9[79:72]),  .acc(arr_out[8][2]));
  PE pe_8_3(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq11), .left_in(left_seq3[35:27]),  .top_in(top_seq8[71:64]),  .pe_rst_seq(             ), .right_out(left_seq4[35:27]),  .bottom_out(top_seq9[71:64]),  .acc(arr_out[8][3]));
  PE pe_8_4(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq12), .left_in(left_seq4[35:27]),  .top_in(top_seq8[63:56]),  .pe_rst_seq(             ), .right_out(left_seq5[35:27]),  .bottom_out(top_seq9[63:56]),  .acc(arr_out[8][4]));
  PE pe_8_5(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq13), .left_in(left_seq5[35:27]),  .top_in(top_seq8[55:48]),  .pe_rst_seq(             ), .right_out(left_seq6[35:27]),  .bottom_out(top_seq9[55:48]),  .acc(arr_out[8][5]));
  PE pe_8_6(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq14), .left_in(left_seq6[35:27]),  .top_in(top_seq8[47:40]),  .pe_rst_seq(             ), .right_out(left_seq7[35:27]),  .bottom_out(top_seq9[47:40]),  .acc(arr_out[8][6]));
  PE pe_8_7(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq15), .left_in(left_seq7[35:27]),  .top_in(top_seq8[39:32]),  .pe_rst_seq(             ), .right_out(left_seq8[35:27]),  .bottom_out(top_seq9[39:32]),  .acc(arr_out[8][7]));
  PE pe_8_8(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq16), .left_in(left_seq8[35:27]),  .top_in(top_seq8[31:24]),  .pe_rst_seq(             ), .right_out(left_seq9[35:27]),  .bottom_out(top_seq9[31:24]),  .acc(arr_out[8][8]));
  PE pe_8_9(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq17), .left_in(left_seq9[35:27]),  .top_in(top_seq8[23:16]),  .pe_rst_seq(             ), .right_out(left_seq10[35:27]), .bottom_out(top_seq9[23:16]),  .acc(arr_out[8][9]));
  PE pe_8_10(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq18), .left_in(left_seq10[35:27]), .top_in(top_seq8[15: 8]),  .pe_rst_seq(             ), .right_out(left_seq11[35:27]), .bottom_out(top_seq9[15: 8]),  .acc(arr_out[8][10]));
  PE pe_8_11(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq19), .left_in(left_seq11[35:27]), .top_in(top_seq8[ 7: 0]),  .pe_rst_seq(sys_rst_seq20), .right_out(     right[35:27]), .bottom_out(top_seq9[ 7: 0]),  .acc(arr_out[8][11]));
  
  PE pe_9_0(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq9),  .left_in(left_seq0[26:18]),  .top_in(top_seq9[95:88]),  .pe_rst_seq(             ), .right_out(left_seq1[26:18]),  .bottom_out(top_seq10[95:88]), .acc(arr_out[9][0]));
  PE pe_9_1(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq10), .left_in(left_seq1[26:18]),  .top_in(top_seq9[87:80]),  .pe_rst_seq(             ), .right_out(left_seq2[26:18]),  .bottom_out(top_seq10[87:80]), .acc(arr_out[9][1]));
  PE pe_9_2(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq11), .left_in(left_seq2[26:18]),  .top_in(top_seq9[79:72]),  .pe_rst_seq(             ), .right_out(left_seq3[26:18]),  .bottom_out(top_seq10[79:72]), .acc(arr_out[9][2]));
  PE pe_9_3(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq12), .left_in(left_seq3[26:18]),  .top_in(top_seq9[71:64]),  .pe_rst_seq(             ), .right_out(left_seq4[26:18]),  .bottom_out(top_seq10[71:64]), .acc(arr_out[9][3]));
  PE pe_9_4(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq13), .left_in(left_seq4[26:18]),  .top_in(top_seq9[63:56]),  .pe_rst_seq(             ), .right_out(left_seq5[26:18]),  .bottom_out(top_seq10[63:56]), .acc(arr_out[9][4]));
  PE pe_9_5(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq14), .left_in(left_seq5[26:18]),  .top_in(top_seq9[55:48]),  .pe_rst_seq(             ), .right_out(left_seq6[26:18]),  .bottom_out(top_seq10[55:48]), .acc(arr_out[9][5]));
  PE pe_9_6(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq15), .left_in(left_seq6[26:18]),  .top_in(top_seq9[47:40]),  .pe_rst_seq(             ), .right_out(left_seq7[26:18]),  .bottom_out(top_seq10[47:40]), .acc(arr_out[9][6]));
  PE pe_9_7(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq16), .left_in(left_seq7[26:18]),  .top_in(top_seq9[39:32]),  .pe_rst_seq(             ), .right_out(left_seq8[26:18]),  .bottom_out(top_seq10[39:32]), .acc(arr_out[9][7]));
  PE pe_9_8(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq17), .left_in(left_seq8[26:18]),  .top_in(top_seq9[31:24]),  .pe_rst_seq(             ), .right_out(left_seq9[26:18]),  .bottom_out(top_seq10[31:24]), .acc(arr_out[9][8]));
  PE pe_9_9(.clk(clk), .rst_n(rst_n), .pe_rst(sys_rst_seq18), .left_in(left_seq9[26:18]),  .top_in(top_seq9[23:16]),  .pe_rst_seq(             ), .right_out(left_seq10[26:18]), .bottom_out(top_seq10[23:16]), .acc(arr_out[9][9]));
  PE pe_9_10(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq19), .left_in(left_seq10[26:18]), .top_in(top_seq9[15: 8]),  .pe_rst_seq(             ), .right_out(left_seq11[26:18]), .bottom_out(top_seq10[15: 8]), .acc(arr_out[9][10]));
  PE pe_9_11(.clk(clk),.rst_n(rst_n), .pe_rst(sys_rst_seq20), .left_in(left_seq11[26:18]), .top_in(top_seq9[ 7: 0]),  .pe_rst_seq(sys_rst_seq21), .right_out(     right[26:18]), .bottom_out(top_seq10[7: 0]),  .acc(arr_out[9][11]));
  
  PE pe_10_0(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq10), .left_in(left_seq0[17: 9]),  .top_in(top_seq10[95:88]), .pe_rst_seq(             ), .right_out(left_seq1[17: 9]),  .bottom_out(top_seq11[95:88]), .acc(arr_out[10][0]));
  PE pe_10_1(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq11), .left_in(left_seq1[17: 9]),  .top_in(top_seq10[87:80]), .pe_rst_seq(             ), .right_out(left_seq2[17: 9]),  .bottom_out(top_seq11[87:80]), .acc(arr_out[10][1]));
  PE pe_10_2(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq12), .left_in(left_seq2[17: 9]),  .top_in(top_seq10[79:72]), .pe_rst_seq(             ), .right_out(left_seq3[17: 9]),  .bottom_out(top_seq11[79:72]), .acc(arr_out[10][2]));
  PE pe_10_3(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq13), .left_in(left_seq3[17: 9]),  .top_in(top_seq10[71:64]), .pe_rst_seq(             ), .right_out(left_seq4[17: 9]),  .bottom_out(top_seq11[71:64]), .acc(arr_out[10][3]));
  PE pe_10_4(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq14), .left_in(left_seq4[17: 9]),  .top_in(top_seq10[63:56]), .pe_rst_seq(             ), .right_out(left_seq5[17: 9]),  .bottom_out(top_seq11[63:56]), .acc(arr_out[10][4]));
  PE pe_10_5(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq5[17: 9]),  .top_in(top_seq10[55:48]), .pe_rst_seq(             ), .right_out(left_seq6[17: 9]),  .bottom_out(top_seq11[55:48]), .acc(arr_out[10][5]));
  PE pe_10_6(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq16), .left_in(left_seq6[17: 9]),  .top_in(top_seq10[47:40]), .pe_rst_seq(             ), .right_out(left_seq7[17: 9]),  .bottom_out(top_seq11[47:40]), .acc(arr_out[10][6]));
  PE pe_10_7(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq17), .left_in(left_seq7[17: 9]),  .top_in(top_seq10[39:32]), .pe_rst_seq(             ), .right_out(left_seq8[17: 9]),  .bottom_out(top_seq11[39:32]), .acc(arr_out[10][7]));
  PE pe_10_8(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq18), .left_in(left_seq8[17: 9]),  .top_in(top_seq10[31:24]), .pe_rst_seq(             ), .right_out(left_seq9[17: 9]),  .bottom_out(top_seq11[31:24]), .acc(arr_out[10][8]));
  PE pe_10_9(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq19), .left_in(left_seq9[17: 9]),  .top_in(top_seq10[23:16]), .pe_rst_seq(             ), .right_out(left_seq10[17: 9]), .bottom_out(top_seq11[23:16]), .acc(arr_out[10][9]));
  PE pe_10_10(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq20), .left_in(left_seq10[17: 9]), .top_in(top_seq10[15: 8]), .pe_rst_seq(             ), .right_out(left_seq11[17: 9]), .bottom_out(top_seq11[15: 8]), .acc(arr_out[10][10]));
  PE pe_10_11(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq21), .left_in(left_seq11[17: 9]), .top_in(top_seq10[ 7: 0]), .pe_rst_seq(sys_rst_seq22), .right_out(     right[17: 9]), .bottom_out(top_seq11[ 7: 0]), .acc(arr_out[10][11]));
  
  PE pe_11_0(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq11), .left_in(left_seq0[ 8: 0]),  .top_in(top_seq11[95:88]), .pe_rst_seq(             ), .right_out(left_seq1[ 8: 0]),  .bottom_out(   bottom[95:88]), .acc(arr_out[11][0]));
  PE pe_11_1(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq12), .left_in(left_seq1[ 8: 0]),  .top_in(top_seq11[87:80]), .pe_rst_seq(             ), .right_out(left_seq2[ 8: 0]),  .bottom_out(   bottom[87:80]), .acc(arr_out[11][1]));
  PE pe_11_2(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq13), .left_in(left_seq2[ 8: 0]),  .top_in(top_seq11[79:72]), .pe_rst_seq(             ), .right_out(left_seq3[ 8: 0]),  .bottom_out(   bottom[79:72]), .acc(arr_out[11][2]));
  PE pe_11_3(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq14), .left_in(left_seq3[ 8: 0]),  .top_in(top_seq11[71:64]), .pe_rst_seq(             ), .right_out(left_seq4[ 8: 0]),  .bottom_out(   bottom[71:64]), .acc(arr_out[11][3]));
  PE pe_11_4(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq15), .left_in(left_seq4[ 8: 0]),  .top_in(top_seq11[63:56]), .pe_rst_seq(             ), .right_out(left_seq5[ 8: 0]),  .bottom_out(   bottom[63:56]), .acc(arr_out[11][4]));
  PE pe_11_5(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq16), .left_in(left_seq5[ 8: 0]),  .top_in(top_seq11[55:48]), .pe_rst_seq(             ), .right_out(left_seq6[ 8: 0]),  .bottom_out(   bottom[55:48]), .acc(arr_out[11][5]));
  PE pe_11_6(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq17), .left_in(left_seq6[ 8: 0]),  .top_in(top_seq11[47:40]), .pe_rst_seq(             ), .right_out(left_seq7[ 8: 0]),  .bottom_out(   bottom[47:40]), .acc(arr_out[11][6]));
  PE pe_11_7(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq18), .left_in(left_seq7[ 8: 0]),  .top_in(top_seq11[39:32]), .pe_rst_seq(             ), .right_out(left_seq8[ 8: 0]),  .bottom_out(   bottom[39:32]), .acc(arr_out[11][7]));
  PE pe_11_8(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq19), .left_in(left_seq8[ 8: 0]),  .top_in(top_seq11[31:24]), .pe_rst_seq(             ), .right_out(left_seq9[ 8: 0]),  .bottom_out(   bottom[31:24]), .acc(arr_out[11][8]));
  PE pe_11_9(.clk(clk), .rst_n(rst_n),.pe_rst(sys_rst_seq20), .left_in(left_seq9[ 8: 0]),  .top_in(top_seq11[23:16]), .pe_rst_seq(             ), .right_out(left_seq10[ 8: 0]), .bottom_out(   bottom[23:16]), .acc(arr_out[11][9]));
  PE pe_11_10(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq21), .left_in(left_seq10[ 8: 0]), .top_in(top_seq11[15: 8]), .pe_rst_seq(             ), .right_out(left_seq11[ 8: 0]), .bottom_out(   bottom[15: 8]), .acc(arr_out[11][10]));
  PE pe_11_11(.clk(clk),.rst_n(rst_n),.pe_rst(sys_rst_seq22), .left_in(left_seq11[ 8: 0]), .top_in(top_seq11[ 7: 0]), .pe_rst_seq(sys_rst_seq23), .right_out(     right[ 8: 0]), .bottom_out(   bottom[ 7: 0]), .acc(arr_out[11][11]));

  //15
  assign row0_out = {arr_out[0][0], arr_out[0][1], arr_out[0][2], arr_out[0][3], arr_out[0][4], arr_out[0][5], arr_out[0][6], arr_out[0][7], arr_out[0][8], arr_out[0][9], arr_out[0][10], arr_out[0][11]};
  assign row1_out = {arr_out[1][0], arr_out[1][1], arr_out[1][2], arr_out[1][3], arr_out[1][4], arr_out[1][5], arr_out[1][6], arr_out[1][7], arr_out[1][8], arr_out[1][9], arr_out[1][10], arr_out[1][11]};
  assign row2_out = {arr_out[2][0], arr_out[2][1], arr_out[2][2], arr_out[2][3], arr_out[2][4], arr_out[2][5], arr_out[2][6], arr_out[2][7], arr_out[2][8], arr_out[2][9], arr_out[2][10], arr_out[2][11]};
  assign row3_out = {arr_out[3][0], arr_out[3][1], arr_out[3][2], arr_out[3][3], arr_out[3][4], arr_out[3][5], arr_out[3][6], arr_out[3][7], arr_out[3][8], arr_out[3][9], arr_out[3][10], arr_out[3][11]};
  assign row4_out = {arr_out[4][0], arr_out[4][1], arr_out[4][2], arr_out[4][3], arr_out[4][4], arr_out[4][5], arr_out[4][6], arr_out[4][7], arr_out[4][8], arr_out[4][9], arr_out[4][10], arr_out[4][11]};
  assign row5_out = {arr_out[5][0], arr_out[5][1], arr_out[5][2], arr_out[5][3], arr_out[5][4], arr_out[5][5], arr_out[5][6], arr_out[5][7], arr_out[5][8], arr_out[5][9], arr_out[5][10], arr_out[5][11]};
  assign row6_out = {arr_out[6][0], arr_out[6][1], arr_out[6][2], arr_out[6][3], arr_out[6][4], arr_out[6][5], arr_out[6][6], arr_out[6][7], arr_out[6][8], arr_out[6][9], arr_out[6][10], arr_out[6][11]};
  assign row7_out = {arr_out[7][0], arr_out[7][1], arr_out[7][2], arr_out[7][3], arr_out[7][4], arr_out[7][5], arr_out[7][6], arr_out[7][7], arr_out[7][8], arr_out[7][9], arr_out[7][10], arr_out[7][11]};
  assign row8_out = {arr_out[8][0], arr_out[8][1], arr_out[8][2], arr_out[8][3], arr_out[8][4], arr_out[8][5], arr_out[8][6], arr_out[8][7], arr_out[8][8], arr_out[8][9], arr_out[8][10], arr_out[8][11]};
  assign row9_out = {arr_out[9][0], arr_out[9][1], arr_out[9][2], arr_out[9][3], arr_out[9][4], arr_out[9][5], arr_out[9][6], arr_out[9][7], arr_out[9][8], arr_out[9][9], arr_out[9][10], arr_out[9][11]};
  assign row10_out = {arr_out[10][0], arr_out[10][1], arr_out[10][2], arr_out[10][3], arr_out[10][4], arr_out[10][5], arr_out[10][6], arr_out[10][7], arr_out[10][8], arr_out[10][9], arr_out[10][10], arr_out[10][11]};
  assign row11_out = {arr_out[11][0], arr_out[11][1], arr_out[11][2], arr_out[11][3], arr_out[11][4], arr_out[11][5], arr_out[11][6], arr_out[11][7], arr_out[11][8], arr_out[11][9], arr_out[11][10], arr_out[11][11]};

  //13
  always @(posedge clk) begin
    if (!rst_n) begin
      out_valid_pp0 <= 0;
      out_valid_pp1 <= 0;
      out_valid_pp2 <= 0;
      out_valid_pp3 <= 0;
      out_valid_pp4 <= 0;
      out_valid_pp5 <= 0;
      out_valid_pp6 <= 0;
      out_valid_pp7 <= 0;
      out_valid_pp8 <= 0;
      out_valid_pp9 <= 0;
      out_valid <= 0;
    end
    else begin
      out_valid_pp0 <= in_valid;
      out_valid_pp1 <= out_valid_pp0;
      out_valid_pp2 <= out_valid_pp1;
      out_valid_pp3 <= out_valid_pp2;
      out_valid_pp4 <= out_valid_pp3;
      out_valid_pp5 <= out_valid_pp4;
      out_valid_pp6 <= out_valid_pp5;
      out_valid_pp7 <= out_valid_pp6;
      out_valid_pp8 <= out_valid_pp7;
      out_valid_pp9 <= out_valid_pp8;
      out_valid <= out_valid_pp9;
    end
  end
endmodule
*/

module PE(
    clk, 
    rst_n,
    pe_rst, 
    left_in, 
    top_in, 
    pe_rst_seq,
    right_out, 
    bottom_out, 
    acc
);

  input clk;
  input rst_n;
  input pe_rst;
  input [8:0] left_in;
  input [7:0] top_in;
  output reg pe_rst_seq;
  output reg signed [8:0] right_out;
  output reg signed [7:0] bottom_out;
  output reg signed [31:0] acc;

  reg signed [17:0] mul;
  reg signed [31:0] add_acc;
  reg signed [31:0] acc_comb;


  always @(posedge clk) begin
    if (!rst_n) begin
      pe_rst_seq <= 0;
      right_out <= 9'd0;
      bottom_out <= 8'd0;
    end else begin
      pe_rst_seq <= pe_rst;
      right_out <= left_in;
      bottom_out <= top_in;
    end
  end
  
  always @(*) begin
    mul = right_out * bottom_out;
    add_acc = pe_rst_seq ? 'd0 : acc;
    acc_comb = add_acc + mul;
  end

  always @(posedge clk) begin
    if (!rst_n) acc <= 32'd0;
    else acc <= acc_comb;
  end
endmodule

// global_buffer_bram is for using BRAM to integrate systolic array
module global_buffer_bram #(parameter ADDR_BITS=8, parameter DATA_BITS=8)(
  input                      clk,
  input                      rst_n,
  input                      ram_en,
  input                      wr_en,
  input      [ADDR_BITS-1:0] index,
  input      [DATA_BITS-1:0] data_in,
  output reg [DATA_BITS-1:0] data_out
  );

  parameter DEPTH = 2**ADDR_BITS;

  reg [DATA_BITS-1:0] gbuff [DEPTH-1:0];

  always @ (negedge clk) begin
    if (ram_en) begin
      if(wr_en) begin
        gbuff[index] <= data_in;
      end else begin
        data_out <= gbuff[index];
      end
    end
  end
endmodule

/**
  Example of instantiating a global_buffer_bram: 

  global_buffer_bram #(
    .ADDR_BITS(12), // ADDR_BITS 12 -> generates 2^12 entries
    .DATA_BITS(32)  // DATA_BITS 32 -> 32 bits for each entries
  )
  gbuff_A(
    .clk(clk),
    .rst_n(1'b1),
    .ram_en(1'b1),
    .wr_en(A_wr_en),
    .index(A_index),
    .data_in(A_data_in),
    .data_out(A_data_out)
  );

*/
